{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

module Cardano.Node.Configuration.TopologyP2P
  ( TopologyError(..)
  , NetworkTopology(..)
  , PublicRootPeers(..)
  , LocalRootPeersGroup(..)
  , LocalRootPeersGroups(..)
  , RootConfig(..)
  , NodeHostIPAddress(..)
  , NodeHostIPv4Address(..)
  , NodeHostIPv6Address(..)
  , NodeSetup(..)
  , PeerAdvertise(..)
  , UseLedger(..)
  , nodeAddressToSockAddr
  , readTopologyFile
  , readTopologyFileOrError
  , rootConfigToRelayAccessPoint
  )
where

import           Cardano.Prelude hiding (ap)
import           Prelude (String)

import qualified Control.Exception as Exception
import           Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as Text

import           "contra-tracer" Control.Tracer (Tracer, traceWith)

import           Cardano.Node.Configuration.POM (NodeConfiguration (..))
import           Cardano.Slotting.Slot (SlotNo (..))

import           Cardano.Node.Configuration.NodeAddress
import           Cardano.Node.Configuration.Topology (TopologyError (..))
import           Cardano.Node.Startup (StartupTrace (..))
import           Cardano.Node.Types

import           Ouroboros.Network.NodeToNode (PeerAdvertise (..))
import           Ouroboros.Network.PeerSelection.LedgerPeers (UseLedgerAfter (..))
import           Ouroboros.Network.PeerSelection.RelayAccessPoint (RelayAccessPoint (..))



-- | A newtype wrapper around 'UseLedgerAfter' which provides 'FromJSON' and
-- 'ToJSON' instances.
--
-- 'UseLedgerAfter' is used to configure from which slot a p2p node can use on
-- chain root peers.
--
newtype UseLedger = UseLedger UseLedgerAfter deriving (Eq, Show)

instance FromJSON UseLedger where
  parseJSON (Data.Aeson.Number n) =
    if n >= 0 then return $ UseLedger $ UseLedgerAfter $ SlotNo $ floor n
              else return $ UseLedger   DontUseLedger
  parseJSON _ = mzero

instance ToJSON UseLedger where
  toJSON (UseLedger (UseLedgerAfter (SlotNo n))) = Number $ fromIntegral n
  toJSON (UseLedger DontUseLedger)               = Number (-1)

data NodeSetup = NodeSetup
  { nodeId          :: !Word64
  , nodeIPv4Address :: !(Maybe NodeIPv4Address)
  , nodeIPv6Address :: !(Maybe NodeIPv6Address)
  , producers       :: ![RootConfig]
  , useLedger       :: !UseLedger
  } deriving (Eq, Show)

instance FromJSON NodeSetup where
  parseJSON = withObject "NodeSetup" $ \o ->
                NodeSetup
                  <$> o .:  "nodeId"
                  <*> o .:  "nodeIPv4Address"
                  <*> o .:  "nodeIPv6Address"
                  <*> o .:  "producers"
                  <*> o .:? "useLedgerAfterSlot" .!= UseLedger DontUseLedger

instance ToJSON NodeSetup where
  toJSON ns =
    object
      [ "nodeId"             .= nodeId ns
      , "nodeIPv4Address"    .= nodeIPv4Address ns
      , "nodeIPv6Address"    .= nodeIPv6Address ns
      , "producers"          .= producers ns
      , "useLedgerAfterSlot" .= useLedger ns
      ]


-- | Each root peer consists of a list of access points and a shared
-- 'PeerAdvertise' field.
--
data RootConfig = RootConfig
  { rootAccessPoints :: [RelayAccessPoint]
    -- ^ a list of relay access points, each of which is either an ip address
    -- or domain name and a port number.
  , rootAdvertise    :: PeerAdvertise
    -- ^ 'advertise' configures whether the root should be advertised through
    -- gossip.
  } deriving (Eq, Show)

instance FromJSON RootConfig where
  parseJSON = withObject "RootConfig" $ \o ->
                RootConfig
                  <$> o .:  "accessPoints"
                  <*> o .:? "advertise" .!= DoNotAdvertisePeer

instance ToJSON RootConfig where
  toJSON ra =
    object
      [ "accessPoints" .= rootAccessPoints ra
      , "advertise"    .= rootAdvertise ra
      ]

-- | Transforms a 'RootConfig' into a pair of 'RelayAccessPoint' and its
-- corresponding 'PeerAdvertise' value.
--
rootConfigToRelayAccessPoint
  :: RootConfig
  -> [(RelayAccessPoint, PeerAdvertise)]
rootConfigToRelayAccessPoint RootConfig { rootAccessPoints, rootAdvertise } =
    [ (ap, rootAdvertise) | ap <- rootAccessPoints ]


-- | A local root peers group.  Local roots are treated by the outbound
-- governor in a special way.  The node will make sure that a node has the
-- requested number ('valency') of connections to the local root peer group.
--
data LocalRootPeersGroup = LocalRootPeersGroup
  { localRoots :: RootConfig
  , valency    :: Int
  } deriving (Eq, Show)

-- | Does not use the 'FromJSON' instance of 'RootConfig', so that
-- 'accessPoints', 'advertise' and 'valency' fields are attached to the same
-- object.
instance FromJSON LocalRootPeersGroup where
  parseJSON = withObject "LocalRootPeersGroup" $ \o ->
                LocalRootPeersGroup
                  <$> parseJSON (Object o)
                  <*> o .: "valency"

instance ToJSON LocalRootPeersGroup where
  toJSON lrpg =
    object
      [ "accessPoints" .= rootAccessPoints (localRoots lrpg)
      , "advertise" .= rootAdvertise (localRoots lrpg)
      , "valency" .= valency lrpg
      ]

newtype LocalRootPeersGroups = LocalRootPeersGroups
  { groups :: [LocalRootPeersGroup]
  } deriving (Eq, Show)

instance FromJSON LocalRootPeersGroups where
  parseJSON = fmap LocalRootPeersGroups . parseJSONList

instance ToJSON LocalRootPeersGroups where
  toJSON = toJSONList . groups

newtype PublicRootPeers = PublicRootPeers
  { publicRoots :: RootConfig
  } deriving (Eq, Show)

instance FromJSON PublicRootPeers where
  parseJSON = fmap PublicRootPeers . parseJSON

instance ToJSON PublicRootPeers where
  toJSON = toJSON . publicRoots

data NetworkTopology = RealNodeTopology !LocalRootPeersGroups ![PublicRootPeers] !UseLedger
  deriving (Eq, Show)

instance FromJSON NetworkTopology where
  parseJSON = withObject "NetworkTopology" $ \o ->
                RealNodeTopology <$> (o .: "localRoots"                                     )
                                 <*> (o .: "publicRoots"                                    )
                                 <*> (o .:? "useLedgerAfterSlot" .!= UseLedger DontUseLedger)

instance ToJSON NetworkTopology where
  toJSON top =
    case top of
      RealNodeTopology lrpg prp ul -> object [ "localRoots"         .= lrpg
                                             , "publicRoots"        .= prp
                                             , "useLedgerAfterSlot" .= ul
                                             ]

--
-- Legacy p2p topology file format
--

-- | A newtype wrapper which provides legacy 'FromJSON' instances.
--
newtype Legacy a = Legacy { getLegacy :: a }

instance FromJSON (Legacy a) => FromJSON (Legacy [a]) where
  parseJSON = fmap (Legacy . map getLegacy) . parseJSONList

instance FromJSON (Legacy LocalRootPeersGroup) where
  parseJSON = withObject "LocalRootPeersGroup" $ \o ->
                fmap Legacy $ LocalRootPeersGroup
                  <$> o .: "localRoots"
                  <*> o .: "valency"

instance FromJSON (Legacy LocalRootPeersGroups) where
  parseJSON = withObject "LocalRootPeersGroups" $ \o ->
                Legacy . LocalRootPeersGroups . getLegacy
                  <$> o .: "groups"

instance FromJSON (Legacy PublicRootPeers) where
  parseJSON = withObject "PublicRootPeers" $ \o ->
                Legacy . PublicRootPeers
                  <$> o .: "publicRoots"

instance FromJSON (Legacy NetworkTopology) where
  parseJSON = fmap Legacy
            . withObject "NetworkTopology" (\o ->
                RealNodeTopology <$> fmap getLegacy (o .: "LocalRoots")
                                 <*> fmap getLegacy (o .: "PublicRoots")
                                 <*> (o .:? "useLedgerAfterSlot" .!= UseLedger DontUseLedger))

-- | Read the `NetworkTopology` configuration from the specified file.
--
readTopologyFile :: Tracer IO (StartupTrace blk)
                 -> NodeConfiguration -> IO (Either Text NetworkTopology)
readTopologyFile tr nc = do
  eBs <- Exception.try $ BS.readFile (unTopology $ ncTopologyFile nc)

  case eBs of
    Left e -> return . Left $ handler e
    Right bs ->
      let bs' = LBS.fromStrict bs in
      first handlerJSON (eitherDecode bs')
      `combine`
      first handlerJSON (eitherDecode bs')

 where
  combine :: Either Text NetworkTopology
          -> Either Text (Legacy NetworkTopology)
          -> IO (Either Text NetworkTopology)
  combine a b = case (a, b) of
    (Right {}, _)     -> return a
    (_, Right {})     -> traceWith tr NetworkConfigLegacy
                           >> return (getLegacy <$> b)
    (Left _, Left _)  -> -- ignore parsing error of legacy format
                         return a

  handler :: IOException -> Text
  handler e = Text.pack $ "Cardano.Node.Configuration.Topology.readTopologyFile: "
                        ++ displayException e
  handlerJSON :: String -> Text
  handlerJSON err = "Is your topology file formatted correctly? \
                    \Expecting P2P Topology file format. \
                    \The port and valency fields should be numerical. \
                    \If you specified the correct topology file \
                    \make sure that you correctly setup EnableP2P \
                    \configuration flag. " <> Text.pack err

readTopologyFileOrError :: Tracer IO (StartupTrace blk)
                        -> NodeConfiguration -> IO NetworkTopology
readTopologyFileOrError tr nc =
      readTopologyFile tr nc
  >>= either (\err -> panic $ "Cardano.Node.Configuration.TopologyP2P.readTopologyFile: "
                           <> err)
             pure
