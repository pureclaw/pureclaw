module PureClaw.Agent.Completion
  ( -- * Completion function builder
    buildCompleter
    -- * Pure completion logic (exported for testing)
  , slashCompletions
  ) where

import Control.Exception
import Data.Char qualified as Char
import Data.IORef
import Data.List qualified as L
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Clock qualified as Time
import System.Console.Haskeline qualified as HL
import System.Timeout qualified as Timeout

import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands
import PureClaw.Core.Types
import PureClaw.Providers.Class

-- | TTL cache for model listing results (30 seconds).
data ModelCache = ModelCache
  { _mc_models :: [ModelId]
  , _mc_expiry :: Time.UTCTime
  }

-- | Build a haskeline 'CompletionFunc' from a live 'AgentEnv' reference.
-- Creates an internal cache for model listing results.
-- The IORef is read at completion time, so it reflects hot-swapped providers.
buildCompleter :: IORef (Maybe AgentEnv) -> IO (HL.CompletionFunc IO)
buildCompleter envRef = do
  cacheRef <- newIORef Nothing
  pure (completerImpl envRef cacheRef)

completerImpl :: IORef (Maybe AgentEnv) -> IORef (Maybe ModelCache) -> HL.CompletionFunc IO
completerImpl envRef cacheRef (leftOfCursor, _rightOfCursor) = do
  let line = reverse leftOfCursor
  mEnv <- readIORef envRef
  dynamicCandidates <- getDynamicCandidates mEnv cacheRef line
  let static = slashCompletions line
      allCandidates = L.nub (static ++ dynamicCandidates)
  let wordStart = lastWord line
  if null allCandidates
    then pure (leftOfCursor, [])
    else do
      let completions = map (\c ->
            HL.Completion
              { HL.replacement = drop (length wordStart) c
              , HL.display = c
              , HL.isFinished = not (hasSubcommands c)
              }) allCandidates
      pure (leftOfCursor, completions)

-- | Extract the last word being typed.
lastWord :: String -> String
lastWord = reverse . takeWhile (/= ' ') . reverse

-- | Check if a completion target has further subcommands.
hasSubcommands :: String -> Bool
hasSubcommands candidate =
  let lowerCandidate = map Char.toLower candidate
  in any (\spec ->
    let syntax = map Char.toLower (T.unpack (_cs_syntax spec))
    in syntax /= lowerCandidate && (lowerCandidate ++ " ") `L.isPrefixOf` syntax
    ) allCommandSpecs

-- | Pure static completions for slash commands.
slashCompletions :: String -> [String]
slashCompletions line
  | not ("/" `L.isPrefixOf` stripped) = []
  | stripped == "/" = L.nub (map commandName allCommandSpecs)
  | ' ' `notElem` stripped =
      filter (matchesCI stripped) (L.nub (map commandName allCommandSpecs))
  | otherwise =
      let (cmd, rest) = break (== ' ') stripped
          partial = dropWhile (== ' ') rest
      in completeSubcommands cmd partial
  where
    stripped = dropWhile (== ' ') line

-- | Complete subcommands for a known command prefix.
completeSubcommands :: String -> String -> [String]
completeSubcommands cmd partial =
  let lowerCmd = map Char.toLower cmd
      matchingSpecs = filter (\s -> map Char.toLower (commandName s) == lowerCmd) allCommandSpecs
      subcommands = concatMap (extractSubcommands lowerCmd) matchingSpecs
  in filter (matchesCI partial) subcommands

-- | Extract subcommand names from a CommandSpec syntax string.
extractSubcommands :: String -> CommandSpec -> [String]
extractSubcommands cmdPrefix spec =
  let syntax = T.unpack (_cs_syntax spec)
      rest = dropWhile (== ' ') (drop (length cmdPrefix) syntax)
  in case words rest of
    (sub : _)
      | not (isPlaceholder sub) -> [sub]
    _ -> []

-- | Check if a word is a placeholder like @\<name\>@ or @[N]@.
isPlaceholder :: String -> Bool
isPlaceholder ('<' : _) = True
isPlaceholder ('[' : _) = True
isPlaceholder _         = False

-- | Get dynamic completions that require IO.
getDynamicCandidates :: Maybe AgentEnv -> IORef (Maybe ModelCache) -> String -> IO [String]
getDynamicCandidates Nothing _ _ = pure []
getDynamicCandidates (Just env) cacheRef line = do
  let lower = map Char.toLower (dropWhile (== ' ') line)
  if "/target " `L.isPrefixOf` lower
    then do
      let partial = drop 8 (dropWhile (== ' ') line)
      -- Complete with running harness names + available model names
      harnesses <- readIORef (_env_harnesses env)
      let harnessNames = map T.unpack (Map.keys harnesses)
      models <- getCachedModels env cacheRef
      let modelNames = map (T.unpack . unModelId) models
      pure (filter (matchesCI partial) (harnessNames ++ modelNames))
  else if "/msg " `L.isPrefixOf` lower
    then do
      let rest = drop 5 (dropWhile (== ' ') line)
      -- Only complete the first argument (target name), not the message body
      if ' ' `notElem` rest
        then do
          harnesses <- readIORef (_env_harnesses env)
          let harnessNames = map T.unpack (Map.keys harnesses)
          pure (filter (matchesCI rest) harnessNames)
        else pure []
  else if "/harness start " `L.isPrefixOf` lower
    then do
      let partial = drop 15 (dropWhile (== ' ') line)
          names = concatMap (\(canonical, aliases, _) ->
            T.unpack canonical : map T.unpack aliases) knownHarnesses
      pure (filter (matchesCI partial) names)
  else if "/provider " `L.isPrefixOf` lower
    then do
      let partial = drop 10 (dropWhile (== ' ') line)
          names = ["anthropic", "openai", "openrouter", "ollama"]
      pure (filter (matchesCI partial) names)
  else
    pure []

-- | Get models with a 30-second TTL cache.
getCachedModels :: AgentEnv -> IORef (Maybe ModelCache) -> IO [ModelId]
getCachedModels env cacheRef = do
  now <- Time.getCurrentTime
  mCache <- readIORef cacheRef
  case mCache of
    Just cache | _mc_expiry cache > now -> pure (_mc_models cache)
    _ -> do
      models <- getModelsWithTimeout env
      let expiry = Time.addUTCTime 30 now
      writeIORef cacheRef (Just (ModelCache models expiry))
      pure models

-- | Query the provider for available models with a 3-second timeout.
getModelsWithTimeout :: AgentEnv -> IO [ModelId]
getModelsWithTimeout env = do
  mProvider <- readIORef (_env_provider env)
  case mProvider of
    Nothing -> pure []
    Just provider -> do
      result <- try @SomeException (Timeout.timeout 3000000 (listModels provider))
      case result of
        Right (Just models) -> pure models
        _                   -> pure []

-- | Case-insensitive prefix match.
matchesCI :: String -> String -> Bool
matchesCI prefix candidate =
  map Char.toLower prefix `L.isPrefixOf` map Char.toLower candidate

-- | Extract the command name (first word) from a CommandSpec's syntax.
commandName :: CommandSpec -> String
commandName spec =
  case words (T.unpack (_cs_syntax spec)) of
    (cmd : _) -> cmd
    []        -> T.unpack (_cs_syntax spec)
