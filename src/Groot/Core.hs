{-# LANGUAGE RankNTypes #-}

module Groot.Core where

import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Lens
import Control.Monad.Catch
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Reader
import Data.Conduit
import qualified Data.Conduit.List as CL
import Data.Maybe (listToMaybe, isJust)
import Data.Time.Clock
import Network.AWS hiding (await)
import Network.AWS.Data.Text
import Network.AWS.ECS hiding (cluster)

import Groot.Data
import Groot.Exception

type GrootAction = ExceptT GrootError AWS

type GrootActionIO m a = ReaderT Env m a

runActionIO :: MonadAWS m => GrootActionIO m a -> Env -> IO a
runActionIO action = undefined
  --runReaderT (\env -> hoist (runResourceT . runAWS env) action)

handleGrootError :: forall a. GrootError -> IO a
handleGrootError err = fail $ show err

runActionM :: Env -> GrootAction a -> (a -> IO b) -> IO b
runActionM env action success = do
  result <- runResourceT . runAWS env . runExceptT $ action
  case result of
    Left err -> handleGrootError err
    Right a -> success a

runAction :: Env -> GrootAction a -> (a -> b) -> IO b
runAction env action success = runActionM env action (\x -> return $ success x)

-- Clusters

clusterName :: Cluster -> Maybe ClusterRef
clusterName cluster = ClusterRef <$> cluster ^. cClusterName

clusterExists :: MonadAWS m => ClusterRef -> m Bool
clusterExists clusterRef = isJust <$> (runMaybeT $ findCluster clusterRef)

findCluster :: MonadAWS m => ClusterRef -> MaybeT m Cluster
findCluster (ClusterRef cref) = MaybeT $ do
  res <- send $ dcClusters .~ [cref] $ describeClusters
  return $ listToMaybe (res ^. dcrsClusters)

getCluster :: MonadAWS m => ClusterRef -> m Cluster
getCluster clusterRef = do
  cluster <- runMaybeT $ findCluster clusterRef
  case cluster of
    Just c  -> return c
    Nothing -> throwM $ clusterNotFound clusterRef

fetchClusters :: MonadAWS m => Source m Cluster
fetchClusters =
  let getClusterBatch batch = do
        res <- send $ dcClusters .~ batch $ describeClusters
        return $ res ^. dcrsClusters
  in paginate listClusters
      =$= CL.concatMapM (\x -> getClusterBatch (x ^. lcrsClusterARNs))

-- Container Instances

fetchInstancesC :: MonadAWS m => [InstanceRef] -> Conduit ClusterRef m ContainerInstance
fetchInstancesC instances =
  awaitForever (\cref -> yieldM $ do
    res <- send $ dciCluster ?~ (toText cref) $ dciContainerInstances .~ (toText <$> instances) $ describeContainerInstances
    return $ res ^. dcisrsContainerInstances
  ) =$= CL.concat

fetchAllInstancesC :: MonadAWS m => Conduit ClusterRef m ContainerInstance
fetchAllInstancesC = awaitForever (\cref -> yieldM . sourceToList $ fetchInstances cref) =$= CL.concat

findInstances :: MonadAWS m => [InstanceRef] -> Maybe ClusterRef -> Source m ContainerInstance
findInstances instances (Just clusterRef) =
  yield clusterRef =$= fetchInstancesC instances
findInstances instances _ =
  fetchClusters =$= CL.mapMaybe clusterName =$= fetchInstancesC instances

findInstance :: MonadAWS m => InstanceRef -> Maybe ClusterRef -> MaybeT m ContainerInstance
findInstance iref cref = MaybeT . runConduit $ findInstances [iref] cref =$= CL.head

getInstance :: MonadAWS m => InstanceRef -> Maybe ClusterRef -> m ContainerInstance
getInstance iref cref = do
  inst <- runMaybeT $ findInstance iref cref
  case inst of
    Just x  -> return x
    Nothing -> throwM $ instanceNotFound iref cref

fetchInstances :: MonadAWS m => ClusterRef -> Source m ContainerInstance
fetchInstances (ClusterRef cref) =
  let getInstanceBatch []    = return []
      getInstanceBatch batch = do
        res <- send $ dciCluster ?~ cref $ dciContainerInstances .~ batch $ describeContainerInstances
        return $ res ^. dcisrsContainerInstances
  in paginate (lciCluster ?~ cref $ listContainerInstances)
     =$= CL.concatMapM (\x -> getInstanceBatch (view lcirsContainerInstanceARNs x))

fetchAllInstances :: MonadAWS m => Source m ContainerInstance
fetchAllInstances = fetchClusters
  =$= CL.mapMaybe clusterName
  =$= fetchAllInstancesC

-- Tasks

fetchTasksC :: MonadAWS m => [TaskRef] -> Conduit ClusterRef m Task
fetchTasksC tasks =
  awaitForever (\cref -> yieldM $ do
    res <- send $ dtCluster ?~ (toText cref) $ dtTasks .~ (toText <$> tasks) $ describeTasks
    return $ listToMaybe $ res ^. dtrsTasks
  ) =$= CL.concat

fetchAllTasksC :: MonadAWS m => Conduit ClusterRef m Task
fetchAllTasksC = awaitForever (\cref -> yieldM . sourceToList $ fetchTasks cref) =$= CL.concat

findTasks :: MonadAWS m => [TaskRef] -> Maybe ClusterRef -> Source m Task
findTasks tasks (Just clusterRef) =
  yield clusterRef =$= fetchTasksC tasks
findTasks tasks _ =
  fetchClusters =$= CL.mapMaybe clusterName =$= fetchTasksC tasks

findTask :: MonadAWS m => TaskRef -> Maybe ClusterRef -> MaybeT m Task
findTask tref cref = MaybeT . runConduit $ findTasks [tref] cref =$= CL.head

getTask :: MonadAWS m => TaskRef -> Maybe ClusterRef -> m Task
getTask tref cref = do
  t <- runMaybeT $ findTask tref cref
  case t of
    Just x  -> return x
    Nothing -> throwM $ taskNotFound tref cref

fetchTasks :: MonadAWS m => ClusterRef -> Source m Task
fetchTasks (ClusterRef cref) =
  let getTaskBatch []    = return []
      getTaskBatch batch = do
        res <- send $ dtCluster ?~ cref $ dtTasks .~ batch $ describeTasks
        return $ res ^. dtrsTasks
  in paginate (ltCluster ?~ cref $ listTasks)
     =$= CL.concatMapM (\x -> getTaskBatch (view ltrsTaskARNs x))

fetchAllTasks :: MonadAWS m => Source m Task
fetchAllTasks = fetchClusters
  =$= CL.mapMaybe clusterName
  =$= fetchAllTasksC

-- Task Definitions

getTaskDef :: MonadAWS m => TaskDefRef -> MaybeT m TaskDefinition
getTaskDef (TaskDefRef arn) = MaybeT $ do
  res <- send $ describeTaskDefinition arn
  return $ res ^. desrsTaskDefinition

taskDefFromTask :: MonadAWS m => Task -> MaybeT m TaskDefinition
taskDefFromTask tsk = do
  arn <- MaybeT . return $ TaskDefRef <$> tsk ^. tTaskDefinitionARN
  getTaskDef arn

fetchTaskDefs :: (MonadAWS m, Foldable f) => f TaskDefFilter -> Source m TaskDefinition
fetchTaskDefs filters =
  let tds :: TaskDefStatus -> TaskDefinitionStatus
      tds TaskActive   = TDSActive
      tds TaskInactive = TDSInactive

      withFilter :: TaskDefFilter -> ListTaskDefinitions -> ListTaskDefinitions
      withFilter (FamilyFilter (TaskFamily f)) = ltdFamilyPrefix ?~ f
      withFilter (StatusFilter s) = ltdStatus ?~ (tds s)

  in paginate (foldr withFilter listTaskDefinitions filters)
     =$= CL.concatMap (view ltdrsTaskDefinitionARNs)
     =$= CL.map TaskDefRef
     =$= CL.mapMaybeM (\x -> runMaybeT (getTaskDef x))

-- Services

serviceCoords :: ContainerService -> Maybe ServiceCoords
serviceCoords service = ServiceCoords <$> serviceRef <*> clusterRef
  where serviceRef = ServiceRef <$> service ^. csServiceARN
        clusterRef = ClusterRef <$> service ^. csClusterARN

fetchServicesC :: MonadAWS m => [ServiceRef] -> Conduit ClusterRef m ContainerService
fetchServicesC services =
  awaitForever (\cref -> yieldM $ do
    res <- send $ dCluster ?~ (toText cref) $ dServices .~ (toText <$> services) $ describeServices
    return $ listToMaybe (res ^. dssrsServices)
  ) =$= CL.concat

fetchAllServicesC :: MonadAWS m => Conduit ClusterRef m ContainerService
fetchAllServicesC = awaitForever (\cref -> yieldM . sourceToList $ fetchServices cref) =$= CL.concat

findServices :: MonadAWS m => [ServiceRef] -> Maybe ClusterRef -> Source m ContainerService
findServices services (Just clusterRef) =
  yield clusterRef =$= fetchServicesC services
findServices services _ =
  fetchClusters =$= CL.mapMaybe clusterName =$= fetchServicesC services

findService :: MonadAWS m => ServiceRef -> Maybe ClusterRef -> MaybeT m ContainerService
findService sref cref = MaybeT . runConduit $ findServices [sref] cref =$= CL.head

getService :: MonadAWS m => ServiceRef -> Maybe ClusterRef -> m ContainerService
getService serviceName clusterRef = do
  serv <- runMaybeT $ findService serviceName clusterRef
  case serv of
    Just x  -> return x
    Nothing -> throwM $ serviceNotFound serviceName clusterRef

fetchServices :: MonadAWS m => ClusterRef -> Source m ContainerService
fetchServices (ClusterRef cref) =
  let getServiceBatch []    = return []
      getServiceBatch batch = do
        res <- send $ dCluster ?~ cref $ dServices .~ batch $ describeServices
        return $ res ^. dssrsServices
  in paginate (lsCluster ?~ cref $ listServices)
     =$= CL.concatMapM (\x -> getServiceBatch (view lsrsServiceARNs x))

fetchAllServices :: Source AWS ContainerService
fetchAllServices = fetchClusters
  =$= CL.mapMaybe clusterName
  =$= fetchAllServicesC

serviceEventLog :: MonadAWS m
                => ServiceCoords
                -> Bool
                -> Source m ServiceEvent
serviceEventLog (ServiceCoords serviceName clusterRef) inf = yield Nothing =$= loop
  where serviceEvents :: MonadAWS m => Maybe UTCTime -> m [ServiceEvent]
        serviceEvents lastEventTime = do
          service <- getService serviceName (Just clusterRef)
          events <- return $ service ^.csEvents
          return $ case lastEventTime of
            Nothing -> events
            Just t  -> takeWhile (\ev -> maybe False (> t) $ ev ^. seCreatedAt) events
    
        fetch :: MonadAWS m => Maybe UTCTime -> m ([ServiceEvent], Maybe UTCTime)
        fetch lastEventTime = do
          events <- serviceEvents lastEventTime
          return $ (events, listToMaybe events >>= view seCreatedAt)

        loop :: MonadAWS m => Conduit (Maybe UTCTime) m ServiceEvent
        loop = do
          prev <- await
          case prev of
            Nothing            -> return ()
            Just lastEventTime -> do
              (events, nextTime) <- lift $ fetch lastEventTime
              CL.sourceList $ reverse events
              if inf then do
                leftover $ nextTime <|> lastEventTime
                liftIO $ threadDelay 1000000
                loop
              else return ()

