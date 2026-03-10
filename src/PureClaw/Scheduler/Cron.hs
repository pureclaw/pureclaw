module PureClaw.Scheduler.Cron
  ( -- * Cron expression
    CronExpr (..)
  , CronField (..)
  , parseCronExpr
    -- * Matching
  , cronMatches
    -- * Scheduler
  , CronJob (..)
  , CronScheduler
  , mkCronScheduler
  , addJob
  , removeJob
  , tickScheduler
  , schedulerJobNames
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time

-- | A single field in a cron expression.
data CronField
  = Wildcard                -- ^ @*@ — matches any value
  | Exact Int              -- ^ A specific value
  | Range Int Int          -- ^ @a-b@ — inclusive range
  | Step CronField Int     -- ^ @field/n@ — every n-th value
  | ListField [CronField]  -- ^ @a,b,c@ — multiple values
  deriving stock (Show, Eq)

-- | A parsed cron expression with 5 fields: minute, hour, day-of-month,
-- month, day-of-week.
data CronExpr = CronExpr
  { _ce_minute     :: CronField
  , _ce_hour       :: CronField
  , _ce_dayOfMonth :: CronField
  , _ce_month      :: CronField
  , _ce_dayOfWeek  :: CronField
  }
  deriving stock (Show, Eq)

-- | Parse a cron expression string (5 space-separated fields).
-- Returns 'Left' with an error message on failure.
parseCronExpr :: Text -> Either String CronExpr
parseCronExpr input =
  case T.words (T.strip input) of
    [m, h, dom, mon, dow] -> do
      minute <- parseField m
      hour <- parseField h
      dayOfMonth <- parseField dom
      month <- parseField mon
      dow' <- parseField dow
      Right CronExpr
        { _ce_minute     = minute
        , _ce_hour       = hour
        , _ce_dayOfMonth = dayOfMonth
        , _ce_month      = month
        , _ce_dayOfWeek  = dow'
        }
    _ -> Left "Expected 5 space-separated fields"

-- | Parse a single cron field.
parseField :: Text -> Either String CronField
parseField txt
  | T.any (== ',') txt = do
      let parts = T.splitOn "," txt
      fields <- traverse parseField parts
      Right (ListField fields)
  | T.any (== '/') txt =
      case T.splitOn "/" txt of
        [base, step] -> do
          baseField <- parseBaseField base
          case readInt step of
            Just n  -> Right (Step baseField n)
            Nothing -> Left ("Invalid step: " <> T.unpack step)
        _ -> Left ("Invalid step expression: " <> T.unpack txt)
  | otherwise = parseBaseField txt

-- | Parse a base field (no commas or slashes).
parseBaseField :: Text -> Either String CronField
parseBaseField txt
  | txt == "*" = Right Wildcard
  | T.any (== '-') txt =
      case T.splitOn "-" txt of
        [lo, hi] -> case (readInt lo, readInt hi) of
          (Just l, Just h) -> Right (Range l h)
          _                -> Left ("Invalid range: " <> T.unpack txt)
        _ -> Left ("Invalid range: " <> T.unpack txt)
  | otherwise = case readInt txt of
      Just n  -> Right (Exact n)
      Nothing -> Left ("Invalid field: " <> T.unpack txt)

-- | Read an integer from text.
readInt :: Text -> Maybe Int
readInt txt = case reads (T.unpack txt) of
  [(n, "")] -> Just n
  _         -> Nothing

-- | Check if a cron expression matches a given UTC time.
cronMatches :: CronExpr -> UTCTime -> Bool
cronMatches expr time =
  let (_year, monthVal, day) = toGregorian (utctDay time)
      TimeOfDay hourVal minuteVal _ = timeToTimeOfDay (utctDayTime time)
      -- Sunday = 0 in cron, Data.Time uses Monday = 1 .. Sunday = 7
      dowRaw = let d = dayOfWeek (utctDay time)
               in case d of
                    Sunday -> 0
                    _      -> fromEnum d
  in fieldMatches (_ce_minute expr) minuteVal
     && fieldMatches (_ce_hour expr) hourVal
     && fieldMatches (_ce_dayOfMonth expr) day
     && fieldMatches (_ce_month expr) monthVal
     && fieldMatches (_ce_dayOfWeek expr) dowRaw

-- | Check if a cron field matches a specific integer value.
fieldMatches :: CronField -> Int -> Bool
fieldMatches Wildcard _ = True
fieldMatches (Exact n) v = n == v
fieldMatches (Range lo hi) v = v >= lo && v <= hi
fieldMatches (Step base n) v =
  case base of
    Wildcard   -> v `mod` n == 0
    Range lo _ -> v >= lo && (v - lo) `mod` n == 0
    _          -> fieldMatches base v
fieldMatches (ListField fields) v = any (`fieldMatches` v) fields

-- | A scheduled job with a cron expression and an IO action.
data CronJob = CronJob
  { _cj_name :: Text
  , _cj_expr :: CronExpr
  , _cj_action :: IO ()
  }

-- | A scheduler that manages named cron jobs.
newtype CronScheduler = CronScheduler
  { _cs_jobs :: Map Text CronJob
  }

-- | Create an empty scheduler.
mkCronScheduler :: CronScheduler
mkCronScheduler = CronScheduler Map.empty

-- | Add a job to the scheduler. Replaces any existing job with the same name.
addJob :: CronJob -> CronScheduler -> CronScheduler
addJob job sched = sched { _cs_jobs = Map.insert (_cj_name job) job (_cs_jobs sched) }

-- | Remove a job by name.
removeJob :: Text -> CronScheduler -> CronScheduler
removeJob name sched = sched { _cs_jobs = Map.delete name (_cs_jobs sched) }

-- | Get all job names and their cron expressions.
schedulerJobNames :: CronScheduler -> [(Text, CronExpr)]
schedulerJobNames sched =
  [(name, _cj_expr job) | (name, job) <- Map.toList (_cs_jobs sched)]

-- | Run all jobs whose cron expression matches the given time.
-- Returns the names of jobs that were executed.
tickScheduler :: CronScheduler -> UTCTime -> IO [Text]
tickScheduler sched time = do
  let matching = Map.filter (\job -> cronMatches (_cj_expr job) time) (_cs_jobs sched)
  mapM_ _cj_action (Map.elems matching)
  pure (Map.keys matching)
