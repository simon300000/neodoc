-- | Resolve ambiguities by combining the parsed usage section with any parsed
-- | Option sections, as well as some best effort guessing.
-- |
-- | ===
-- |
-- | Thoughts:
-- |    * It appears there is never a reason to fail hard. It would be nice if
-- |      we could produce warnings, however -> Write monad?

module Language.Docopt.Solver where

import Prelude
import Debug.Trace
import Data.Either (Either(..))
import Data.Maybe.Unsafe (fromJust)
import Data.Maybe (Maybe(..), isJust, maybe, maybe', isNothing)
import Data.List (List(..), filter, head, foldM, concat, (:), singleton
                , catMaybes, toList, last, init, length)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Data.Foldable (foldl)
import Control.MonadPlus (guard)
import Control.Plus (empty)
import Control.Alt ((<|>))
import Data.Monoid (mempty)
import Control.Monad.Error.Class (throwError)
import qualified Data.Array as A
import qualified Data.String as Str

import Language.Docopt.Types
import Language.Docopt.Parser.Desc (Desc(..))
import qualified Language.Docopt.Parser.Desc           as Desc
import qualified Language.Docopt.Parser.Usage          as U
import qualified Language.Docopt.Parser.Usage.Argument as U
import qualified Language.Docopt.Parser.Usage.Option   as UO

data Result = Consumed (List Argument) | Unconsumed (List Argument)

solveBranch :: U.Branch -> List Desc -> Either SolveError Branch
solveBranch as ds = Branch <$> f as
  where f :: U.Branch -> Either SolveError (List Argument)
        f Nil = return Nil
        f (Cons x Nil) = do
          m <- solveArgs x Nothing
          return $ case m of
            Unconsumed zs -> zs
            Consumed   zs -> zs
        f (Cons x (Cons y xs)) = do
          m <- solveArgs x (Just y)
          case m of
            Unconsumed zs -> (zs ++) <$> f (y:xs)
            Consumed   zs -> (zs ++) <$> f xs

        -- | Solve two adjacent arguments.
        -- | Should the first argument be an option with an argument that
        -- | matches an adjacent command or positional, consume the adjacent
        -- | argument from the input (consume).
        solveArgs :: U.Argument
                  -> Maybe U.Argument
                  -> Either SolveError Result

        solveArgs (U.EOA) _
          = Unconsumed <<< singleton <$> return (EOA)

        solveArgs (U.Command s) _
          = Unconsumed <<< singleton <$> return (Command s)

        solveArgs (U.Positional s r) _
          = Unconsumed <<< singleton <$> return (Positional s r)

        solveArgs (U.Group o bs r) _
          = Unconsumed <<< singleton <$> do
            flip (Group o) r <$> do
              flip solveBranch ds `traverse` bs

        solveArgs (U.Option (UO.LOpt o)) y = do

          -- XXX: Is `head` the right thing to do here? What if there are more
          -- matches? That would indicate ambigiutiy and needs to be treated,
          -- possibly with an error?
          let opt = flip maybe' id
                      (\_ -> Option Nothing
                                    (Just o.name)
                                    (toArg o.arg)
                                    (o.repeatable))
                      (head $ catMaybes $ convert <$> ds)

          case opt of
            -- XXX: Non-exhaustive on purpose. How to improve?
            (Option f n a' _) ->
              if (argMatches o.arg a')
                then return unit
                else throwError $ DescriptionError $ ArgumentMismatchError {
                        option: {
                          flag: f
                        , name: n
                        , arg:  o.arg
                        }
                      , description: {
                          arg: a' <#> \(OptionArgument an _) -> an
                        }
                      }

          -- Look ahead if any of the following arguments should be consumed.
          -- Return either `Nothing` to signify that nothing should be consumed
          -- or a value signifieng that it should be consumed, and the
          -- `isRepeated` should be inherited.
          let adjArg = if o.repeatable
                then Nothing
                else
                  case y of
                    Just (U.Positional n r) ->
                      case opt of
                        (Option _ _ (Just (OptionArgument n' _)) _)
                          | n == n' -> Just r
                        _ -> Nothing
                    Just (U.Command n) ->
                      case opt of
                        (Option _ _ (Just (OptionArgument n' _)) _)
                          | n == n' -> Just false
                        _ -> Nothing
                    _ -> Nothing

          -- Apply adjacent argument
          return $ maybe'
            (\_ -> Unconsumed $ singleton opt)
            (\r -> case opt of
              -- XXX: non-exhaustive, because doesn't need to be...
              (Option f n a _) -> do
                Consumed $ singleton $ Option f n a r
            )
            adjArg

          where
            convert :: Desc -> Maybe Argument
            convert (Desc.OptionDesc (Desc.Option { name=Desc.Long n', arg=a' }))
              | Str.toUpper n' == Str.toUpper o.name
              = return $ Option Nothing
                                (Just o.name)
                                (resolveOptArg o.arg a')
                                (o.repeatable)
            convert (Desc.OptionDesc (Desc.Option { name=Desc.Full f n', arg=a' }))
              | Str.toUpper n' == Str.toUpper o.name
              = return $ Option (Just f)
                                (Just o.name)
                                (resolveOptArg o.arg a')
                                (o.repeatable)
            convert _ = Nothing

        solveArgs (U.OptionStack (UO.SOpt o)) y = do

          -- Figure out trailing flag, in order to couple it with an adjacent
          -- option where needed.
          let fs' = toList o.stack
              x   = case last fs' of
                      Just f' -> Tuple (o.flag:(fromJust $ init fs')) f'
                      Nothing -> Tuple Nil o.flag
              fs'' = fst x
              f''  = snd x

          xs <- match false `traverse` fs''
          x  <- match true f''

          case x of
            -- XXX: Non-exhaustive on purpose. How to improve?
            (Option f n a' _) ->
              if (argMatches o.arg a')
                then return unit
                else throwError $ DescriptionError $ ArgumentMismatchError {
                        option: {
                          flag: f
                        , name: n
                        , arg:  o.arg
                        }
                      , description: {
                          arg: a' <#> \(OptionArgument an _) -> an
                        }
                      }

          -- Look ahead if any of the following arguments should be consumed.
          -- Return either `Nothing` to signify that nothing should be consumed
          -- or a value signifieng that it should be consumed, and the
          -- `isRepeated` should be inherited.
          let adjArg = if (isRepeatable x)
                then Nothing
                else
                  case y of
                    Just (U.Positional n r) ->
                      case x of
                        (Option _ _ (Just (OptionArgument n' _)) _)
                          | Str.toUpper n == Str.toUpper n' -> Just r
                        _ -> Nothing
                    Just (U.Command n) ->
                      case x of
                        (Option _ _ (Just (OptionArgument n' _)) _)
                          | Str.toUpper n == Str.toUpper n' -> Just false
                        _ -> Nothing
                    _ -> Nothing

          -- Apply adjacent argument
          return $ maybe'
            (\_ -> Unconsumed $ xs ++ singleton x)
            (\r -> case x of
              -- XXX: Non-exhaustive on purpose. How to improve?
              (Option f n a' _) -> do
                Consumed $ xs ++ (singleton $ Option f n a' r)
            )
            adjArg

          where
            match :: Boolean -> Char -> Either SolveError Argument
            match isTrailing f = do
              return $ flip maybe' id
                        (\_ -> Option (Just f)
                                      Nothing
                                      (toArg o.arg)
                                      o.repeatable)
                        (head $ catMaybes $ convert f isTrailing <$> ds)

            convert :: Char -> Boolean -> Desc -> Maybe Argument
            convert f isTrailing (Desc.OptionDesc (Desc.Option { name=Desc.Flag f', arg=a' }))
              | (f == f')
                && (isTrailing || isNothing a')
              = return $ Option (Just f)
                                Nothing
                                (resolveOptArg o.arg a')
                                o.repeatable
            convert f isTrailing (Desc.OptionDesc (Desc.Option { name=Desc.Full f' n, arg=a' }))
              | (f == f')
                && (isTrailing || isNothing a')
              = return $ Option (Just f)
                                (Just n)
                                (resolveOptArg o.arg a')
                                o.repeatable
            convert _ _ _ = Nothing

        -- | Resolve an option's argument name against that given in the
        -- | description, returning the most complete argument known.
        resolveOptArg :: Maybe String
                      -> Maybe Desc.Argument
                      -> Maybe OptionArgument
        resolveOptArg (Just n) Nothing = return $ OptionArgument n Nothing
        resolveOptArg Nothing (Just (Desc.Argument a))
          = do
          -- XXX: The conversion to `StringValue` should not be needed,
          -- `Desc.Argument` should be of type `Maybe Value`.
          return $ OptionArgument a.name (StringValue <$> a.default)
        resolveOptArg (Just an) (Just (Desc.Argument a))
          = do
          -- XXX: Do we need to guard that `an == a.name` here?
          -- XXX: The conversion to `StringValue` should not be needed,
          -- `Desc.Argument` should be of type `Maybe Value`.
          return $ OptionArgument a.name (StringValue <$> a.default)
        resolveOptArg _ _ = Nothing

        toArg:: Maybe String -> Maybe OptionArgument
        toArg a = a >>= \an -> return $ OptionArgument an Nothing

        argMatches :: Maybe String
                   -> Maybe OptionArgument
                   -> Boolean
        argMatches a a'
          =  (isNothing a)
          || (isNothing a && isNothing a')
          || (maybe false id do
              a' >>= \(OptionArgument an' _) -> do
                an <- a
                return (Str.toUpper an == Str.toUpper an')
            )

solveUsage :: U.Usage -> List Desc -> Either SolveError Usage
solveUsage (U.Usage _ bs) ds = Usage <$> do
  traverse (flip solveBranch ds) bs

solve :: (List U.Usage)
      -> (List Desc)
      -> Either SolveError (List Usage)
solve us ds = traverse (flip solveUsage ds) us