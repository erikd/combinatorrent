{-# LANGUAGE FlexibleContexts #-}
module Process.ChokeMgr (
    -- * Types, Channels
      ChokeMgrChannel
    , ChokeMgrMsg(..)
    -- * Interface
    , start
    )
where

import Data.Time.Clock
import Data.List
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Traversable as T

import Control.Concurrent
import Control.Concurrent.CML.Strict
import Control.DeepSeq
import Control.Exception (assert)
import Control.Monad.Reader
import Control.Monad.State


import Prelude hiding (catch, log)

import System.Random

import PeerTypes
import Process
import Supervisor
import Torrent hiding (infoHash)
import Process.Timer as Timer

-- DATA STRUCTURES
----------------------------------------------------------------------

-- | Messages to the Choke Manager
data ChokeMgrMsg = Tick                        -- ^ Request that we run another round
                 | RemovePeer PeerPid          -- ^ Request that this peer is removed
                 | AddPeer PeerPid PeerChannel -- ^ Request that this peer is added
                 | PieceDone PieceNum          -- ^ Note that a given piece is done
                 | BlockComplete PieceNum Block -- ^ Note that a block is complete (endgame)
                 | TorrentComplete              -- ^ Note that the torrent in question is complete

instance NFData ChokeMgrMsg where
  rnf a = a `seq` ()

type ChokeMgrChannel = Channel ChokeMgrMsg

data CF = CF { mgrCh :: ChokeMgrChannel }

instance Logging CF where
  logName _ = "Process.ChokeMgr"

-- PeerDB described below
type ChokeMgrProcess a = Process CF PeerDB a

-- INTERFACE
----------------------------------------------------------------------

start :: ChokeMgrChannel -> Int -> Bool -> SupervisorChan
      -> IO ThreadId
start ch ur weSeed supC = do
    Timer.register 10 Tick ch
    spawnP (CF ch) (initPeerDB $ calcUploadSlots ur Nothing)
            (catchP (forever pgm)
              (defaultStopHandler supC))
  where
    initPeerDB slots = PeerDB 2 weSeed slots M.empty []
    pgm = {-# SCC "ChokeMgr" #-} mgrEvent >>= syncP
    mgrEvent =
          recvWrapPC mgrCh
            (\msg ->
                case msg of
                    Tick          -> tick
                    RemovePeer t  -> removePeer t
                    AddPeer t pCh -> do
                            debugP $ "Adding peer " ++ show t
                            weSeed <- gets seeding
                            addPeer pCh weSeed t
                    BlockComplete pn blk -> informBlockComplete pn blk
                    PieceDone pn -> informDone pn
                    TorrentComplete -> do
                        modify (\s -> s { seeding = True
                                        , peerMap =
                                           M.map (\pi -> pi { pAreSeeding = True })
                                                 $ peerMap s}))
    tick = do debugP "Ticked"
              ch <- asks mgrCh
              Timer.register 10 Tick ch
              updateDB
              runRechokeRound
    removePeer tid = do debugP $ "Removing peer " ++ show tid
                        modify (\db -> db { peerMap = M.delete tid (peerMap db),
                                            peerChain = (peerChain db) \\ [tid] })

-- INTERNAL FUNCTIONS
----------------------------------------------------------------------

type PeerPid = ThreadId -- For now, should probably change

-- | The PeerDB is the database we keep over peers. It maps all the information necessary to determine
--   which peers are interesting to keep uploading to and which are slow. It also keeps track of how
--   far we are in the process of wandering the optimistic unchoke chain.
data PeerDB = PeerDB
    { chokeRound :: Int       -- ^ Counted down by one from 2. If 0 then we should
                              --   advance the peer chain.
    , seeding :: Bool         -- ^ True if we are seeding the torrent.
                              --   In a multi-torrent world, this has to change.
    , uploadSlots :: Int      -- ^ Current number of upload slots
    , peerMap :: PeerMap      -- ^ Map of peers
    , peerChain ::  [PeerPid] -- ^ The order in which peers are optimistically unchoked
    }

-- | The PeerInfo structure maps, for each peer pid, its accompanying informative data for the PeerDB
data PeerInfo = PeerInfo
      { pChokingUs :: Bool -- ^ True if the peer is choking us
      , pDownRate :: Double -- ^ The rate of the peer in question, bytes downloaded in last window
      , pUpRate   :: Double -- ^ The rate of the peer in question, bytes uploaded in last window
      , pChannel :: PeerChannel -- ^ The channel on which to communicate with the peer
      , pInterestedInUs :: Bool -- ^ Reflection from Peer DB
      , pAreSeeding :: Bool -- ^ True if this peer is connected on a torrent we seed
      , pIsASeeder :: Bool -- ^ True if the peer is a seeder
      }

type PeerMap = M.Map PeerPid PeerInfo

-- | Auxilliary data structure. Used in the rechoking process.
type RechokeData = (PeerPid, PeerInfo)

-- | Comparison with inverse ordering
compareInv :: Ord a => a -> a -> Ordering
compareInv x y =
    case compare x y of
        LT -> GT
        EQ -> EQ
        GT -> LT

comparingWith :: Ord a => (a -> a -> Ordering) -> (b -> a) -> b -> b -> Ordering
comparingWith comp project x y =
    comp (project x) (project y)

-- | Leechers are sorted by their current download rate. We want to keep fast peers around.
sortLeech :: [RechokeData] -> [RechokeData]
sortLeech = sortBy (comparingWith compareInv $ pDownRate . snd)

-- | Seeders are sorted by their current upload rate.
sortSeeds :: [RechokeData] -> [RechokeData]
sortSeeds = sortBy (comparingWith compareInv $ pUpRate . snd)

-- | Advance the peer chain to the next peer eligible for optimistic
--   unchoking. That is, skip peers which are not interested in our pieces
--   and peers which are not choking us. The former we can't send any data to,
--   so we can't get better speeds at them. The latter are already sending us data,
--   so we know how good they are as peers.
advancePeerChain :: ChokeMgrProcess [PeerPid]
advancePeerChain = do
    peers <- gets peerChain
    mp    <- gets peerMap
    lPeers <- T.mapM (lookupPeer mp) peers
    let (front, back) = break (\(_, p) -> pInterestedInUs p && pChokingUs p) lPeers
    return $ map fst $ back ++ front
  where
    lookupPeer mp peer = case M.lookup peer mp of
                            Nothing -> fail "Could not look up peer in map"
                            Just p -> return (peer, p)

-- | Add a peer to the Peer Database
addPeer :: PeerChannel -> Bool -> PeerPid -> ChokeMgrProcess ()
addPeer pCh weSeeding tid = do
    addPeerChain tid
    modify (\db -> db { peerMap = M.insert tid initialPeerInfo (peerMap db)})
  where
    initialPeerInfo = PeerInfo { pChokingUs = True
                               , pDownRate = 0.0
                               , pUpRate   = 0.0
                               , pChannel = pCh
                               , pInterestedInUs = False
                               , pAreSeeding = weSeeding
                               , pIsASeeder = False -- May get updated quickly
                               }

-- | Insert a Peer randomly into the Peer chain. Threads the random number generator
--   through.
addPeerChain :: PeerPid -> ChokeMgrProcess ()
addPeerChain pid = do
    ls <- gets peerChain
    pt <- liftIO $ getStdRandom (\gen -> randomR (0, length ls - 1) gen)
    let (front, back) = splitAt pt ls
    modify (\db -> db { peerChain = (front ++ pid : back) })

-- | Calculate the amount of upload slots we have available. If the
--   number of slots is explicitly given, use that. Otherwise we
--   choose the slots based the current upload rate set. The faster
--   the rate, the more slots we allow.
calcUploadSlots :: Int -> Maybe Int -> Int
calcUploadSlots _ (Just n) = n
calcUploadSlots rate Nothing | rate <= 0 = 7 -- This is just a guess
                             | rate <  9 = 2
                             | rate < 15 = 3
                             | rate < 42 = 4
                             | otherwise = calcRate $ fromIntegral rate
  where calcRate :: Double -> Int
        calcRate x = round $ sqrt (x * 0.6)

-- | The call @assignUploadSlots c ds ss@ will assume that we have @c@
--   slots for uploading at our disposal. The list @ds@ will be peers
--   that we would like to upload to among the torrents we are
--   currently downloading. The list @ss@ is the same thing but for
--   torrents that we seed. The function returns a pair @(kd,ks)@
--   where @kd@ is the number of downloader slots and @ks@ is the
--   number of seeder slots.
--
--   The function will move surplus slots around so all of them gets used.
assignUploadSlots :: Int -> [RechokeData] -> [RechokeData] -> (Int, Int)
assignUploadSlots slots downloaderPeers seederPeers =
    -- Shuffle surplus slots around so all gets used
    shuffleSeeders . shuffleDownloaders $ (downloaderSlots, seederSlots)
  where
    -- Calculate the slots available for the downloaders and seeders
    --   We allocate 70% of them to leeching and 30% of the to seeding
    --   though we assign at least one slot to both
    slotRound :: Double -> Double -> Int
    slotRound slots fraction = max 1 $ round $ slots * fraction

    downloaderSlots = slotRound (fromIntegral slots) 0.7
    seederSlots     = slotRound (fromIntegral slots) 0.3

    -- Calculate the amount of peers wanting to download and seed
    numDownPeers = length downloaderPeers
    numSeedPeers = length seederPeers

    -- If there is a surplus of downloader slots, then assign them to
    --  the seeder slots
    shuffleDownloaders (dSlots, sSlots) =
        case max 0 (dSlots - numDownPeers) of
          0 -> (dSlots, sSlots)
          k -> (dSlots - k, sSlots + k)

    -- If there is a surplus of seeder slots, then assign these to
    --   the downloader slots. Limit the downloader slots to the number
    --   of downloaders, however
    shuffleSeeders (dSlots, sSlots) =
        case max 0 (sSlots - numSeedPeers) of
          0 -> (dSlots, sSlots)
          k -> (min (dSlots + k) numDownPeers, sSlots - k)

-- | @selectPeers upSlots d s@ selects peers from a list of downloader peers @d@ and a list of seeder
--   peers @s@. The value of @upSlots@ defines the number of upload slots available
selectPeers :: Int -> [RechokeData] -> [RechokeData] -> ChokeMgrProcess (S.Set PeerPid)
selectPeers uploadSlots downPeers seedPeers = do
        -- Construct a set of downloaders (leechers) and a Set of seeders, which have the
        --  current best rates
        let (nDownSlots, nSeedSlots) = assignUploadSlots uploadSlots downPeers seedPeers
            downPids = S.fromList $ map fst $ take nDownSlots $ sortLeech downPeers
            seedPids = S.fromList $ map fst $ take nSeedSlots $ sortSeeds seedPeers
        debugP $ "Slots: " ++ show nDownSlots ++ " downloads, " ++ show nSeedSlots ++ " seeders"
        debugP $ "Electing peers - leechers: " ++ show downPids ++ "; seeders: " ++ show seedPids
        return $ assertSlots (nDownSlots + nSeedSlots) (S.union downPids seedPids)
  where assertSlots slots = assert (uploadSlots >= slots)

-- | Send a message to the peer process at PeerChannel. Message is sent asynchronously
--   to the peer in question. If the system is really loaded, this might
--   actually fail since the order in which messages arrive might be inverted.
msgPeer :: PeerChannel -> PeerMessage -> ChokeMgrProcess ThreadId
msgPeer ch = liftIO . spawn . sync . (transmit ch)

-- | This function performs the choking and unchoking of peers in a round.
performChokingUnchoking :: S.Set PeerPid -> [RechokeData] -> ChokeMgrProcess ()
performChokingUnchoking elected peers =
    do T.mapM (unchoke . snd) electedPeers
       optChoke defaultOptimisticSlots nonElectedPeers
  where
    -- Partition the peers in elected and non-elected
    (electedPeers, nonElectedPeers) = partition (\rd -> S.member (fst rd) elected) peers
    unchoke pi = unchokePeer (pChannel pi)

    -- If we have k optimistic slots, @optChoke k peers@ will unchoke the first
    -- @k@ peers interested in us. The rest will either be unchoked if they are
    -- not interested (ensuring fast start should they become interested); or
    -- they will be choked to avoid TCP/IP congestion.
    optChoke _ [] = return ()
    optChoke 0 ((_, pi) : ps) = do if pInterestedInUs pi
                                     then chokePeer (pChannel pi)
                                     else unchokePeer (pChannel pi)
                                   optChoke 0 ps
    optChoke k ((_, pi) : ps) = if pInterestedInUs pi
                                then unchokePeer (pChannel pi) >> optChoke (k-1) ps
                                else unchokePeer (pChannel pi) >> optChoke k ps
    chokePeer = flip msgPeer ChokePeer
    unchokePeer = flip msgPeer UnchokePeer

-- | Function to split peers into those where we are seeding and those where we are leeching.
--   also prunes the list for peers which are not interesting.
--   TODO: Snubbed peers
splitSeedLeech :: [RechokeData] -> ([RechokeData], [RechokeData])
splitSeedLeech ps = partition (pAreSeeding . snd) $ filter picker ps
  where
    -- TODO: pIsASeeder is always false at the moment
    picker (_, pi) = not (pIsASeeder pi) && pInterestedInUs pi


buildRechokeData :: ChokeMgrProcess [RechokeData]
buildRechokeData = do
    chain <- gets peerChain
    pm    <- gets peerMap
    T.mapM (cPeer pm) chain
  where cPeer pm pid = case M.lookup pid pm of
                            Nothing -> fail "buildRechokeData: Couldn't lookup pid"
                            Just x -> return (pid, x)

rechoke :: ChokeMgrProcess ()
rechoke = do
    peers <- buildRechokeData
    us <- gets uploadSlots
    let (seed, down) = splitSeedLeech peers
    electedPeers <- selectPeers us down seed
    performChokingUnchoking electedPeers peers

-- | Traverse all peers and process them with a thunk.
traversePeers :: (MonadState PeerDB m) => (PeerInfo -> m b) -> m (M.Map PeerPid b)
traversePeers thnk = T.mapM thnk =<< gets peerMap

informDone :: PieceNum -> ChokeMgrProcess ()
informDone pn = traversePeers sendDone >> return ()
  where
    sendDone pi = msgPeer (pChannel pi) (PieceCompleted pn)

informBlockComplete :: PieceNum -> Block -> ChokeMgrProcess ()
informBlockComplete pn blk = traversePeers sendComp >> return ()
  where
    sendComp pi = msgPeer (pChannel pi) (CancelBlock pn blk)

updateDB :: ChokeMgrProcess ()
updateDB = do
    nmp <- traversePeers gatherRate
    modify (\db -> db { peerMap = nmp })
  where
      gatherRate pi = do
        ch <- liftIO channel
        t  <- liftIO getCurrentTime
        ignoreProcessBlock pi (gather t ch pi)
      gather t ch pi = do
        (sendP (pChannel pi) $ PeerStats t ch) >>= syncP
        (uprt, downrt, interested) <- recvP ch (const True) >>= syncP
        return pi { pDownRate = downrt,
                    pUpRate   = uprt,
                    pInterestedInUs = interested } -- TODO: Seeder state

runRechokeRound :: ChokeMgrProcess ()
runRechokeRound = do
    cRound <- gets chokeRound
    if (cRound == 0)
        then do nChain <- advancePeerChain
                modify (\db -> db { chokeRound = 2,
                                    peerChain = nChain })
        else modify (\db -> db { chokeRound = (chokeRound db) - 1 })
    rechoke
