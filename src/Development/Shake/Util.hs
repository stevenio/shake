
-- | A module for useful utility functions for Shake build systems.
module Development.Shake.Util(
    parseMakefile, needMakefileDependencies, neededMakefileDependencies,
    shakeArgsAccumulate, shakeArgsPrune, shakeArgsPruneWith,
    ) where

import Development.Shake
import Development.Shake.Rules.File
import qualified Data.ByteString.Char8 as BS
import qualified Development.Shake.ByteString as BS
import Data.Tuple.Extra
import Control.Applicative
import Data.List
import System.Console.GetOpt
import Data.IORef
import Data.Maybe
import Control.Monad.Extra
import Prelude
import System.IO.Extra as IO


-- | Given the text of a Makefile, extract the list of targets and dependencies. Assumes a
--   small subset of Makefile syntax, mostly that generated by @gcc -MM@.
--
-- > parseMakefile "a: b c\nd : e" == [("a",["b","c"]),("d",["e"])]
parseMakefile :: String -> [(FilePath, [FilePath])]
parseMakefile = map (BS.unpack *** map BS.unpack) . BS.parseMakefile . BS.pack


-- | Depend on the dependencies listed in a Makefile. Does not depend on the Makefile itself.
--
-- > needMakefileDependencies file = need . concatMap snd . parseMakefile =<< liftIO (readFile file)
needMakefileDependencies :: FilePath -> Action ()
needMakefileDependencies file = needBS . concatMap snd . BS.parseMakefile =<< liftIO (BS.readFile file)


-- | Depend on the dependencies listed in a Makefile. Does not depend on the Makefile itself.
--   Use this function to indicate that you have /already/ used the files in question.
--
-- > neededMakefileDependencies file = needed . concatMap snd . parseMakefile =<< liftIO (readFile file)
neededMakefileDependencies :: FilePath -> Action ()
neededMakefileDependencies file = neededBS . concatMap snd . BS.parseMakefile =<< liftIO (BS.readFile file)


-- | Like `shakeArgsWith`, but instead of accumulating a list of flags, apply functions to a default value.
--   Usually used to populate a record structure. As an example of a build system that can use either @gcc@ or @distcc@ for compiling:
--
-- @
--import System.Console.GetOpt
--
--data Flags = Flags {distCC :: Bool} deriving Eq
--flags = [Option \"\" [\"distcc\"] (NoArg $ Right $ \\x -> x{distCC=True}) \"Run distributed.\"]
--
--main = 'shakeArgsAccumulate' 'shakeOptions' flags (Flags False) $ \\flags targets -> return $ Just $ do
--     if null targets then 'want' [\"result.exe\"] else 'want' targets
--     let compiler = if distCC flags then \"distcc\" else \"gcc\"
--     \"*.o\" '%>' \\out -> do
--         'need' ...
--         'cmd' compiler ...
--     ...
-- @
--
--   Now you can pass @--distcc@ to use the @distcc@ compiler.
shakeArgsAccumulate :: ShakeOptions -> [OptDescr (Either String (a -> a))] -> a -> (a -> [String] -> IO (Maybe (Rules ()))) -> IO ()
shakeArgsAccumulate opts flags def f = shakeArgsWith opts flags $ \flags targets -> f (foldl' (flip ($)) def flags) targets


-- | Like 'shakeArgs' but also takes a pruning function. If @--prune@ is passed, then after the build has completed,
--   the second argument is called with a list of the files that the build checked were up-to-date.
shakeArgsPrune :: ShakeOptions -> ([FilePath] -> IO ()) -> Rules () -> IO ()
shakeArgsPrune opts prune rules = shakeArgsPruneWith opts prune [] f
    where f _ files = return $ Just $ if null files then rules else want files >> withoutActions rules


-- | A version of 'shakeArgsPrune' that also takes a list of extra options to use.
shakeArgsPruneWith :: ShakeOptions -> ([FilePath] -> IO ()) -> [OptDescr (Either String a)] -> ([a] -> [String] -> IO (Maybe (Rules ()))) -> IO ()
shakeArgsPruneWith opts prune flags act = do
    let flags2 = Option "P" ["prune"] (NoArg $ Right Nothing) "Remove stale files" : map (fmapOptDescr $ fmap Just) flags
    pruning <- newIORef False
    shakeArgsWith opts flags2 $ \opts args ->
        if any isNothing opts then do
            writeIORef pruning True
            return Nothing
        else
            act (map fromJust opts) args
    whenM (readIORef pruning) $ do
        IO.withTempFile $ \file -> do
            shakeArgsWith opts{shakeLiveFiles=file : shakeLiveFiles opts} flags2 $ \opts args ->
                act (catMaybes opts) args
            src <- lines <$> IO.readFile' file
            prune src

-- fmap is only an instance in later GHC versions, so fake our own version
fmapOptDescr :: (a -> b) -> OptDescr a -> OptDescr b
fmapOptDescr f (Option a b argDescr c) = Option a b (fmapArgDescr f argDescr) c

fmapArgDescr :: (a -> b) -> ArgDescr a -> ArgDescr b
fmapArgDescr f (NoArg a)    = NoArg (f a)
fmapArgDescr f (ReqArg g s) = ReqArg (f . g) s
fmapArgDescr f (OptArg g s) = OptArg (f . g) s
