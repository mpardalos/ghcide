module Development.IDE.Core.Tracing
    ( otTracedHandler
    , otTracedAction
    , startTelemetry
    )
where

import           Development.Shake
import           Development.IDE.Types.Shake
import           Language.Haskell.LSP.Types
import           OpenTelemetry.Eventlog
import qualified Data.ByteString.Char8         as BS
import Control.Concurrent.Extra
import qualified Data.HashMap.Strict as HMap
import Control.Concurrent.Async
import Control.Monad
import Debug.Trace (traceIO)
import Foreign.Storable (Storable(sizeOf))
import HeapSize (runHeapsize, recursiveSizeNoGC)
import Data.List (sortBy)
import Data.Function (on)
import Development.IDE.Core.RuleTypes
import Data.Typeable
import Data.Hashable

-- | Trace a handler using OpenTelemetry. Adds various useful info into tags in the OpenTelemetry span.
otTracedHandler
    :: String -- ^ Message type
    -> String -- ^ Message label
    -> IO a
    -> IO a
otTracedHandler requestType label act =
  let !name =
        if null label
          then BS.pack requestType
          else BS.pack (requestType <> ":" <> show label)
   -- Add an event so all requests can be quickly seen in the viewer without searching
   in withSpan name (\sp -> addEvent sp "" (name <> " received") >> act)

-- | Trace a Shake action using opentelemetry.
otTracedAction
    :: Show k
    => k -- ^ The Action's Key
    -> NormalizedFilePath -- ^ Path to the file the action was run for
    -> Action a -- ^ The action
    -> Action a
otTracedAction key file act = actionBracket
    (do
        sp <- beginSpan (BS.pack (show key))
        setTag sp "File" (BS.pack $ fromNormalizedFilePath file)
        return sp
    )
    endSpan
    (const act)

startTelemetry :: Var Values -> IO ()
startTelemetry stateRef = do
    instrumentFor <- getInstrumentCached <$> (newVar HMap.empty)

    mapBytesInstrument <- mkValueObserver ("value map size_bytes")
    mapCountInstrument <- mkValueObserver ("values map count")

    _ <- regularly 10000 $ -- 100 times/s
        withSpan_ "Measure length" $
        readVar stateRef
        >>= observe mapCountInstrument . length

    _ <- regularly 1000 $
        withSpan_ "Measure Memory" $ do
        values <- readVar stateRef
        let groupedValues =
                sortBy (compare `on` keyFunction . fst) $
                HMap.toList $
                HMap.fromListWith (++)
                [ (k, [v])
                | ((_, k), v) <- HMap.toList values
                ]

        valuesSize <-
          repeatUntilJust $
          runHeapsize $
          forM groupedValues $ \(k,v) -> withSpan ("Measure " <> (BS.pack $ show k)) $ \sp -> do
            instrument <- liftIO $ instrumentFor k
            sizes <- traverse recursiveSizeNoGC v
            let byteSize = (sizeOf (undefined :: Word) *) $ sum sizes
            setTag sp "size" (BS.pack (show byteSize ++ " bytes"))
            observe instrument byteSize
            return byteSize

        observe mapBytesInstrument $ sum valuesSize
        traceIO "=== ALL DONE ==="
    return ()

    where

        regularly :: Int -> IO () -> IO (Async ())
        regularly delay act = async $ forever (act >> threadDelay delay)

        getInstrumentCached :: Var (HMap.HashMap Key ValueObserver) -> Key -> IO ValueObserver
        getInstrumentCached instrumentMap k = HMap.lookup k <$> readVar instrumentMap >>= \case
            Nothing -> do
                instrument <- mkValueObserver (BS.pack (show k ++ " size_bytes"))
                modifyVar_ instrumentMap (return . (HMap.insert k instrument))
                return instrument
            Just v -> return v

-- | Map every key type to an int
--   This is used for sorting key types,
--   where the order matters for cost attribution:
--   shared costs will be attributed to the first key that incurrs them
keyFunction :: Key -> Int
keyFunction (Key k)
  -- Attribute cost to the GhcSession keys first, since many values contain
  --  references to the HscEnv or DynFlags
  | Just GhcSession <- cast k = 0
  | Just GhcSessionIO <- cast k = 1
  | Just GhcSessionDeps <- cast k = 2
  | otherwise = hash k

repeatUntilJust :: Monad m => m (Maybe b) -> m b
repeatUntilJust action = do
    res <- action
    case res of
        Nothing -> repeatUntilJust action
        Just x -> return x
