{-# LANGUAGE OverloadedStrings #-}

module Groot.App.Config
       (
       -- Default config values
         defaultAwsProfileName
       , defaultConfigFile
       , defaultCredsFile
       -- Utilities
       , regionFromConfig
       ) where

import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Control.Monad.Trans.Maybe
import Data.Ini
import Data.Text (Text)
import Network.AWS (Region(..))
import Network.AWS.Data.Text
import System.Directory

defaultAwsProfileName :: Text
defaultAwsProfileName = "default"

defaultConfigFile :: IO FilePath
defaultConfigFile = (++ "/.aws/config") <$> getHomeDirectory

defaultCredsFile :: IO FilePath
defaultCredsFile = (++ "/.aws/credentials") <$> getHomeDirectory

regionFromConfig :: FilePath -> Maybe Text -> MaybeT IO Region
regionFromConfig filename profile = exceptToMaybeT $ do
  ini <- ExceptT $ readIniFile filename
  rid <- ExceptT $ return $ lookupValue (maybe defaultAwsProfileName id profile) "region" ini
  liftIO $ parseRegion rid
    where parseRegion :: Text -> IO Region
          parseRegion rid = do
            parsed <- return $ fromText rid
            case parsed of
              Left err -> fail err
              Right r  -> return r