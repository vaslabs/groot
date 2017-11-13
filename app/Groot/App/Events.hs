module Groot.App.Events
       ( EventOptions
       , grootEventsCli
       , runGrootEvents
       ) where

import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Lens hiding (argument)
import Data.Conduit
import Data.Semigroup ((<>))
import Data.String
import qualified Data.Text as T
import Data.Time
import Network.AWS hiding (await)
import qualified Network.AWS.ECS as ECS
import Options.Applicative
import System.Console.ANSI

import Groot.App.Cli.Parsers (clusterOpt)
import Groot.Core
import Groot.Data
import Groot.Exception

data EventOptions = EventOptions
  { _clusterId   :: Maybe ClusterRef
  , _follow      :: Bool
  , _serviceName :: ServiceRef
  } deriving (Eq, Show)

grootEventsCli :: Parser EventOptions
grootEventsCli = EventOptions
             <$> optional clusterOpt
             <*> switch
               ( long "follow"
              <> short 'f'
              <> help "Follow the trail of events" )
             <*> (fromString <$> argument str (metavar "SERVICE_NAME"))

formatEventTime :: UTCTime -> IO String
formatEventTime time = do
  dt <- utcToLocalZonedTime time
  return $ formatTime defaultTimeLocale "%d/%m/%Y %T" dt

printEvent :: ECS.ServiceEvent -> IO ()
printEvent event = do
  eventTime <- maybe (return "") formatEventTime $ event ^. ECS.seCreatedAt
  setSGR [SetColor Foreground Dull Blue]
  putStr $ eventTime
  setSGR [Reset]
  putStr " "
  putStrLn $ maybe "" T.unpack $ event ^. ECS.seMessage

findServiceCoords :: MonadAWS m => ServiceRef -> m ServiceCoords
findServiceCoords serviceRef = do
  mcoords <- (serviceCoords <$> getService serviceRef Nothing)
  case mcoords of
    Just c  -> return c
    Nothing -> throwM $ serviceNotFound serviceRef Nothing

fetchEvents :: Env -> ServiceCoords -> Bool -> Source IO ECS.ServiceEvent
fetchEvents env coords inf =
  transPipe (runResourceT . runAWS env) $ serviceEventLog coords inf

printEvents :: Sink ECS.ServiceEvent IO ()
printEvents = do
  mevent <- await
  case mevent of
    Just event -> do
      liftIO $ printEvent event
      printEvents
    Nothing -> return ()

runGrootEvents :: EventOptions -> Env -> IO ()
runGrootEvents (EventOptions (Just clusterRef) follow serviceRef) env =
  runConduit $ fetchEvents env (ServiceCoords serviceRef clusterRef) follow =$ printEvents
runGrootEvents (EventOptions Nothing follow serviceRef) env = do
  coords <- runResourceT . runAWS env $ findServiceCoords serviceRef
  runConduit $ fetchEvents env coords follow =$ printEvents
