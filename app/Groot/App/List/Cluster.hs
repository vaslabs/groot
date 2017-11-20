{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}

module Groot.App.List.Cluster
     ( printClusterSummary
     ) where

import Control.Monad.Trans.Maybe
import Control.Lens
import Data.Hashable
import Data.Conduit
import qualified Data.Conduit.List as CL
import Data.Data
import Data.Maybe (maybeToList)
import qualified Data.Text as T
import GHC.Generics
import Network.AWS
import qualified Network.AWS.ECS as ECS
import qualified Text.PrettyPrint.ANSI.Leijen as PP
import Text.PrettyPrint.Tabulate

import Groot.App.List.Base
import Groot.Core
import Groot.Core.Console
import Groot.Data

data ClusterAttr =
    CAName
  | CAStatus
  | CARunningTasks
  | CAPendingTasks
  | CAInstanceCount
  deriving (Eq, Show, Enum, Bounded, Ord, Generic)

instance Hashable ClusterAttr

instance SummaryAttr ClusterAttr where
  type AttrResource ClusterAttr = ECS.Cluster

  attrName CAName          = "Name"
  attrName CAStatus        = "Status"
  attrName CARunningTasks  = "Running Tasks"
  attrName CAPendingTasks  = "Pending Tasks"
  attrName CAInstanceCount = "# Instances"

  attrGetter CAName          = ECS.cClusterName
  attrGetter CAStatus        = ECS.cStatus
  attrGetter CARunningTasks  = toTextGetter ECS.cRunningTasksCount
  attrGetter CAPendingTasks  = toTextGetter ECS.cPendingTasksCount
  attrGetter CAInstanceCount = toTextGetter ECS.cRegisteredContainerInstancesCount

  printAttr CAStatus txt@"INACTIVE" = PP.red . PP.text $ T.unpack txt
  printAttr CAStatus txt@"ACTIVE"   = PP.dullgreen . PP.text $ T.unpack txt
  printAttr _        txt            = PP.text . T.unpack $ txt

defaultClusterAttrs :: [ClusterAttr]
defaultClusterAttrs = [CAName, CAStatus, CARunningTasks, CAPendingTasks, CAInstanceCount]

data ClusterSummary = ClusterSummary
  { name         :: String
  , status       :: String
  , runningTasks :: Int
  , pendingTasks :: Int
  , instances    :: Int 
  } deriving (Eq, Show, Generic, Data)

instance Tabulate ClusterSummary

instance HasSummary ECS.Cluster ClusterSummary where
  summarize cls = ClusterSummary <$> cName <*> cStatus <*> cRunning <*> cPending <*> cInstances
     where cName      = T.unpack <$> cls ^. ECS.cClusterName
           cStatus    = T.unpack <$> cls ^. ECS.cStatus
           cRunning   = cls ^. ECS.cRunningTasksCount
           cPending   = cls ^. ECS.cPendingTasksCount
           cInstances = cls ^. ECS.cRegisteredContainerInstancesCount

summarizeClusters :: Maybe ClusterRef -> AWS [ClusterSummary]
summarizeClusters Nothing  = runConduit $ fetchClusters =$= CL.mapMaybe summarize =$ CL.consume
summarizeClusters (Just c) = maybeToList <$> do
  cl <- runMaybeT (findCluster c)
  return $ cl >>= summarize

summarizeClusters' :: Env -> IO ()
summarizeClusters' env = clusterStream $$ pprintSink defaultClusterAttrs
  where clusterStream :: Source IO [ECS.Cluster]
        clusterStream = transPipe (runResourceT . runAWS env) $ fetchClusters =$= CL.chunksOf 5

printClusterSummary :: Env -> IO ()
printClusterSummary = summarizeClusters'
