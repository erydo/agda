
{-| Agda main module.
-}
module Agda.Main where

import Control.Monad.Except

import qualified Data.List as List
import Data.Maybe

import System.Environment
import System.Console.GetOpt

import Agda.Interaction.Base ( pattern RegularInteraction )
import Agda.Interaction.CommandLine
import Agda.Interaction.ExitCode (AgdaError(..), exitSuccess, exitAgdaWith)
import Agda.Interaction.Options
import Agda.Interaction.Options.Help (Help (..))
import Agda.Interaction.EmacsTop (mimicGHCi)
import Agda.Interaction.JSONTop (jsonREPL)
import Agda.Interaction.Imports (MaybeWarnings'(..))
import Agda.Interaction.FindFile ( SourceFile(SourceFile) )
import qualified Agda.Interaction.Imports as Imp
import qualified Agda.Interaction.Highlighting.Dot as Dot
import qualified Agda.Interaction.Highlighting.LaTeX as LaTeX
import Agda.Interaction.Highlighting.HTML

import Agda.TypeChecking.Monad
import qualified Agda.TypeChecking.Monad.Benchmark as Bench
import Agda.TypeChecking.Errors
import Agda.TypeChecking.Warnings
import Agda.TypeChecking.Pretty

import Agda.Compiler.Backend
import Agda.Compiler.Builtin

import Agda.VersionCommit

import Agda.Utils.FileName (absolute, filePath, AbsolutePath)
import Agda.Utils.Monad
import Agda.Utils.String
import qualified Agda.Utils.Benchmark as UtilsBench

import Agda.Utils.Impossible

-- | The main function
runAgda :: [Backend] -> IO ()
runAgda backends = runAgda' $ builtinBackends ++ backends

-- | The main function without importing built-in backends
runAgda' :: [Backend] -> IO ()
runAgda' backends = runTCMPrettyErrors $ do
  progName <- liftIO getProgName
  argv     <- liftIO getArgs
  conf     <- liftIO $ runOptM $ do
    (bs, opts) <- parseBackendOptions backends argv defaultOptions
    -- The absolute path of the input file, if provided
    inputFile <- maybe (pure Nothing) (fmap Just . liftIO . absolute) (optInputFile opts)
    mode      <- getMainMode bs inputFile opts
    return (bs, opts, mode)

  case conf of
    Left err -> liftIO $ optionError err
    Right (bs, opts, mode) -> case mode of
      MainModeShowHelp hp  -> liftIO $ printUsage bs hp
      MainModePrintVersion -> liftIO $ printVersion bs
      MainModeRun interactor -> do
        setTCLens stBackends bs
        () <$ runAgdaWithOptions generateHTML interactor progName opts

-- | Main execution mode
data MainMode
  = MainModeRun (Interactor ())
  | MainModeShowHelp Help
  | MainModePrintVersion

-- | Determine the main execution mode to run, based on the configured backends and command line options.
-- | This is pure.
getMainMode :: MonadError String m => [Backend] -> Maybe AbsolutePath -> CommandLineOptions -> m MainMode
getMainMode configuredBackends maybeInputFile opts
  | Just hp <- optShowHelp opts = return $ MainModeShowHelp hp
  | optShowVersion opts         = return $ MainModePrintVersion
  | otherwise                   = do
      mi <- getInteractor configuredBackends maybeInputFile opts
      -- If there was no selection whatsoever (e.g. just invoked "agda"), we just show help and exit.
      return $ maybe (MainModeShowHelp GeneralHelp) MainModeRun mi

type Interactor a
    -- Setup/initialization action.
    -- This is separated so that errors can be reported in the appropriate format.
    = TCM ()
    -- Type-checking action
    -> (AbsolutePath -> TCM (Maybe Interface))
    -- Main transformed action.
    -> TCM a

data FrontendType
  = FrontEndEmacs
  | FrontEndJson
  | FrontEndRepl

-- Emacs mode. Note that it ignores the "check" action because it calls typeCheck directly.
emacsModeInteractor :: Interactor ()
emacsModeInteractor setup _check = mimicGHCi setup

-- JSON mode. Note that it ignores the "check" action because it calls typeCheck directly.
jsonModeInteractor :: Interactor ()
jsonModeInteractor setup _check = jsonREPL setup

-- The deprecated repl mode.
replInteractor :: Maybe AbsolutePath -> Interactor ()
replInteractor = runInteractionLoop

-- The interactor to use when there are no frontends or backends specified.
defaultInteractor :: AbsolutePath -> Interactor ()
defaultInteractor file setup check = setup >> (void $ check file)

getInteractor :: MonadError String m => [Backend] -> Maybe AbsolutePath -> CommandLineOptions -> m (Maybe (Interactor ()))
getInteractor configuredBackends maybeInputFile opts = case (maybeInputFile, enabledFrontends, enabledBackends) of
  (Just inputFile, [],             _:_) -> return $ Just $ backendInteraction inputFile enabledBackends
  (Just inputFile, [],              []) -> return $ Just $ defaultInteractor inputFile
  (Nothing,        [],              []) -> return Nothing -- No backends, frontends, or input files specified.
  (Nothing,        [],             _:_) -> throwError $ concat ["No input file specified for ", enabledBackendNames]
  (_,              _:_,            _:_) -> throwError $ concat ["Cannot mix ", enabledFrontendNames, " with ", enabledBackendNames]
  (_,              _:_:_,           []) -> throwError $ concat ["Must not specify multiple ", enabledFrontendNames]
  (_,              [FrontEndRepl],  []) -> return $ Just $ replInteractor maybeInputFile
  (Nothing,        [FrontEndEmacs], []) -> return $ Just $ emacsModeInteractor
  (Nothing,        [FrontEndJson],  []) -> return $ Just $ jsonModeInteractor
  (Just inputFile, [FrontEndEmacs], []) -> throwError $ concat ["Must not specify an input file (", filePath inputFile, ") with --interaction"]
  (Just inputFile, [FrontEndJson],  []) -> throwError $ concat ["Must not specify an input file (", filePath inputFile, ") with --interaction-json"]
  where
    -- NOTE: The notion of a backend being "enabled" *just* refers to this top-level interaction mode selection. The
    -- interaction/interactive front-ends may still invoke available backends even if they are not "enabled".
    isBackendEnabled (Backend b) = isEnabled b (options b)
    enabledBackends = filter isBackendEnabled configuredBackends
    enabledFrontends = [ name | (name, enabled) <-
      [ (FrontEndRepl, optInteractive opts)
      , (FrontEndEmacs, optGHCiInteraction opts)
      , (FrontEndJson, optJSONInteraction opts)
      ], enabled ]
    -- Constructs messages like "(no backend)", "backend ghc", "backends (ghc, ocaml)"
    pluralize w [] = concat ["(no ", w, ")"]
    pluralize w [x] = concat [w, " ", x]
    pluralize w xs = concat [w, "s (", List.intercalate ", " xs, ")"]
    enabledBackendNames = pluralize "backend" [ backendName b | Backend b <- enabledBackends ]
    enabledFrontendNames = pluralize "frontend" (frontendFlagName <$> enabledFrontends)
    frontendFlagName = ("--" ++) . \case
      FrontEndEmacs -> "interaction"
      FrontEndJson -> "interaction-json"
      FrontEndRepl -> "interactive"

-- | Run Agda with parsed command line options and with a custom HTML generator
runAgdaWithOptions
  :: TCM ()             -- ^ HTML generating action
  -> Interactor a       -- ^ Backend interaction
  -> String             -- ^ program name
  -> CommandLineOptions -- ^ parsed command line options
  -> TCM (Maybe a)
runAgdaWithOptions generateHTML interactor progName opts = Just <$> do
          -- Main function.
          -- Bill everything to root of Benchmark trie.
          UtilsBench.setBenchmarking UtilsBench.BenchmarkOn
            -- Andreas, Nisse, 2016-10-11 AIM XXIV
            -- Turn benchmarking on provisionally, otherwise we lose track of time spent
            -- on e.g. LaTeX-code generation.
            -- Benchmarking might be turned off later by setCommandlineOptions

          Bench.billTo [] $
            interactor initialSetup checkFile
          `finally_` do
            -- Print benchmarks.
            Bench.print

            -- Print accumulated statistics.
            printStatistics 1 Nothing =<< useTC lensAccumStatistics
  where
    -- Options are fleshed out here so that (most) errors like
    -- "bad library path" are validated within the interactor,
    -- so that they are reported with the appropriate protocol/formatting.
    initialSetup :: TCM ()
    initialSetup = do
      opts <- addTrustedExecutables opts
      setCommandLineOptions opts

    checkFile :: AbsolutePath -> TCM (Maybe Interface)
    checkFile inputFile = do
        -- Andreas, 2013-10-30 The following 'resetState' kills the
        -- verbosity options.  That does not make sense (see fail/Issue641).
        -- 'resetState' here does not seem to serve any purpose,
        -- thus, I am removing it.
        -- resetState
          let mode = if optOnlyScopeChecking opts
                     then Imp.ScopeCheck
                     else Imp.TypeCheck RegularInteraction

          let file = SourceFile inputFile
          (i, mw) <- Imp.typeCheckMain file mode =<< Imp.sourceInfo file

          -- An interface is only generated if the mode is
          -- Imp.TypeCheck and there are no warnings.
          result <- case (mode, mw) of
            (Imp.ScopeCheck, _)  -> return Nothing
            (_, NoWarnings)      -> return $ Just i
            (_, SomeWarnings ws) -> do
              ws' <- applyFlagsToTCWarnings ws
              case ws' of
                []   -> return Nothing
                cuws -> tcWarningsToError cuws

          reportSDoc "main" 50 $ pretty i

          whenM (optGenerateHTML <$> commandLineOptions) $
            generateHTML

          forMM_ (optDependencyGraph <$> commandLineOptions) $
            Dot.generateDot i

          whenM (optGenerateLaTeX <$> commandLineOptions) $
            LaTeX.generateLaTeX i

          -- Print accumulated warnings
          ws <- tcWarnings . classifyWarnings <$> Imp.getAllWarnings AllWarnings
          unless (null ws) $ do
            let banner = text $ "\n" ++ delimiter "All done; warnings encountered"
            reportSDoc "warning" 1 $
              vcat $ punctuate "\n" $ banner : (prettyTCM <$> ws)

          return result



-- | Print usage information.
printUsage :: [Backend] -> Help -> IO ()
printUsage backends hp = do
  progName <- getProgName
  putStr $ usage standardOptions_ progName hp
  when (hp == GeneralHelp) $ mapM_ (putStr . backendUsage) backends

backendUsage :: Backend -> String
backendUsage (Backend b) =
  usageInfo ("\n" ++ backendName b ++ " backend options") $
    map void (commandLineFlags b)

-- | Print version information.
printVersion :: [Backend] -> IO ()
printVersion backends = do
  putStrLn $ "Agda version " ++ versionWithCommitInfo
  mapM_ putStrLn
    [ "  - " ++ name ++ " backend version " ++ ver
    | Backend Backend'{ backendName = name, backendVersion = Just ver } <- backends ]

-- | What to do for bad options.
optionError :: String -> IO ()
optionError err = do
  prog <- getProgName
  putStrLn $ "Error: " ++ err ++ "\nRun '" ++ prog ++ " --help' for help on command line options."
  exitAgdaWith OptionError

-- | Run a TCM action in IO; catch and pretty print errors.
runTCMPrettyErrors :: TCM () -> IO ()
runTCMPrettyErrors tcm = do
    r <- runTCMTop $ tcm `catchError` \err -> do
      s2s <- prettyTCWarnings' =<< Imp.getAllWarningsOfTCErr err
      s1  <- prettyError err
      let ss = filter (not . null) $ s2s ++ [s1]
      unless (null s1) (liftIO $ putStr $ unlines ss)
      throwError err
    case r of
      Right _ -> exitSuccess
      Left _  -> exitAgdaWith TCMError
  `catchImpossible` \e -> do
    putStr $ show e
    exitAgdaWith ImpossibleError
