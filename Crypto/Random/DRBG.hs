{-# LANGUAGE EmptyDataDecls, FlexibleInstances, TypeSynonymInstances #-}
{-|
 Maintainer: Thomas.DuBuisson@gmail.com
 Stability: beta
 Portability: portable 

This module is the convenience interface for the DRBG (NIST standardized
number-theoretically secure random number generator).  Everything is setup
for using the "crypto-api" 'CryptoRandomGen' type class.  For example,
to seed a new generator with the system secure random ('System.Crypto.Random')
and generate some bytes (stepping the generator along the way) one would do:

@
    gen <- newGenIO :: IO HmacDRBG
    let Right (randomBytes, newGen) = genBytes gen 1024
@
 
 -}

module Crypto.Random.DRBG
	( HmacDRBG, HashDRBG
	, GenXor
	, GenAutoReseed
	, GenBuffered
	, GenSystemRandom
	, getGenSystemRandom
	, module Crypto.Random
	) where

import qualified Crypto.Random.DRBG.HMAC as M
import qualified Crypto.Random.DRBG.Hash as H
import Crypto.Classes
import Crypto.Random
import Crypto.Hash.SHA512 (SHA512)
import Crypto.Hash.SHA384 (SHA384)
import Crypto.Hash.SHA256 (SHA256)
import Crypto.Hash.SHA224 (SHA224)
import Crypto.Hash.SHA1 (SHA1)
import System.Crypto.Random
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Tagged
import Data.Bits (xor)
import Control.Parallel (par)
import Control.Monad (liftM)
import Control.Monad.Error () -- Either instance
import System.IO.Unsafe (unsafeInterleaveIO)

instance H.SeedLength SHA512 where
	seedlen = Tagged 888

instance H.SeedLength SHA384 where
	seedlen = Tagged  888

instance H.SeedLength SHA256 where
	seedlen = Tagged 440

instance H.SeedLength SHA224 where
	seedlen = Tagged 440

instance H.SeedLength SHA1 where
	seedlen = Tagged 440

-- |An alias for an HmacDRBG generator using SHA512.  This is the recommended generator.
type HmacDRBG = M.State SHA512

-- |An Alias for a HashDRBG generator using SHA512.
type HashDRBG = H.State SHA512

newGenAutoReseed :: (CryptoRandomGen a, CryptoRandomGen b) => B.ByteString -> Int -> Either GenError (GenAutoReseed a b)
newGenAutoReseed bs rsInterval=
	let (b1,b2) = B.splitAt (genSeedLength `for` fromRight g1) bs
	    g1 = newGen b1
	    g2 = newGen b2
	    fromRight (Right x) = x
	in case (g1, g2) of
		(Right a, Right b) -> Right $ GenAutoReseed a b rsInterval 0
		(Left e, _) -> Left e
		(_, Left e) -> Left e

instance CryptoRandomGen HmacDRBG where
	newGen bs = Right $ M.instantiate bs B.empty B.empty
	genSeedLength = Tagged (512 `div` 8)
	genBytes req g =
		let res = M.generate g (req * 8) B.empty
		in case res of
			Nothing -> Left NeedReseed
			Just (r,s) -> Right (B.concat . L.toChunks $ r, s)
	genBytesWithEntropy req ai g =
		let res = M.generate g (req * 8) ai
		in case res of
			Nothing -> Left NeedReseed
			Just (r,s) -> Right (B.concat . L.toChunks $ r, s)
	reseed ent g = Right $ M.reseed g ent B.empty

instance CryptoRandomGen HashDRBG where
	newGen bs = Right $ H.instantiate bs B.empty B.empty
	genSeedLength = Tagged $ 512 `div` 8
	genBytes req g = 
		let res = H.generate g (req * 8) B.empty
		in case res of
			Nothing -> Left NeedReseed
			Just (r,s) -> Right (B.concat . L.toChunks $ r, s)
	genBytesWithEntropy req ai g =
		let res = H.generate g (req * 8) ai
		in case res of
			Nothing -> Left NeedReseed
			Just (r,s) -> Right (B.concat . L.toChunks $ r, s)
	reseed ent g = Right $ H.reseed g ent B.empty

helper1 :: Tagged (GenAutoReseed a b) Int -> a
helper1 = const undefined

helper2 :: Tagged (GenAutoReseed a b) Int -> b
helper2 = const undefined

-- |@g :: GenAutoReseed a b@ is a generator of type a that gets
-- automatically reseeded by generator b upon every 32kB generated.
--
-- @reseed g ent@ will reseed both the component generators by
-- breaking ent up into two parts determined by the genSeedLength of each generator.
--
-- @genBytes@ will generate the requested bytes with generator @a@ and reseed @a@
-- using generator @b@ if there has been 32KB of generated data since the last reseed.
-- Note a request for > 32KB of data will be filled in one request to generator @a@ before
-- @a@ is reseeded by @b@.
--
-- @genBytesWithEntropy@ will push the entropy into generator @a@, leaving generator
-- @b@ unchanged unless the count hits 32KB, in which case it is reseeds @a@ 
-- (for a second time) using @b@ as in normal operation via @genBytes@.
data GenAutoReseed a b = GenAutoReseed !a !b !Int !Int

instance (CryptoRandomGen a, CryptoRandomGen b) => CryptoRandomGen (GenAutoReseed a b) where
	{-# SPECIALIZE instance CryptoRandomGen (GenAutoReseed HmacDRBG HmacDRBG) #-}
	newGen bs = newGenAutoReseed bs (2^15)
	genSeedLength =
		let a = helper1 res
		    b = helper2 res
		    res = Tagged $ genSeedLength `for` a + genSeedLength `for` b
		in res
	genBytes req (GenAutoReseed a b rs cnt) = do
		(res, aNew) <- genBytes req a
		gNew <- if (cnt + req) > rs
			  then do (ent,b') <- genBytes (genSeedLength `for` a) b
				  a'  <- reseed ent aNew
				  return (GenAutoReseed a' b' rs 0)
			  else return $ GenAutoReseed aNew b rs (cnt + req)
		return (res, gNew)
	genBytesWithEntropy req entropy (GenAutoReseed a b rs cnt) = do
		(res, aNew) <- genBytesWithEntropy req entropy a
		gNew <- if (cnt + req) > rs
			  then do (ent,b') <- genBytes (genSeedLength `for` a) b
				  a'  <- reseed ent aNew
				  return (GenAutoReseed a' b' rs 0)
			  else return $ GenAutoReseed aNew b rs (cnt + req)
		return (res, gNew)
	reseed ent (GenAutoReseed a b rs _) = do
		let (b1,b2) = B.splitAt (genSeedLength `for` a) ent
		a' <- reseed b1 a
		b' <- reseed b2 b
		return $ GenAutoReseed a' b' rs 0

-- |@g :: GenXor a b@ generates bytes with sub-generators a and b 
-- and exclusive-or's the outputs to produce the resulting bytes.
data GenXor a b = GenXor !a !b

helperXor1 :: Tagged (GenXor a b) c -> a
helperXor1 = const undefined
helperXor2 :: Tagged (GenXor a b) c -> b
helperXor2 = const undefined

instance (CryptoRandomGen a, CryptoRandomGen b) => CryptoRandomGen (GenXor a b) where
	{-# SPECIALIZE instance CryptoRandomGen (GenXor HmacDRBG HmacDRBG) #-}
	newGen bs = do
		let g1 = newGen b1
		    g2 = newGen b2
		    (b1,b2) = B.splitAt (genSeedLength `for` fromRight g1) bs
		    fromRight (Right x) = x
		a <- g1
		b <- g2
		return (GenXor a b)
	genSeedLength =
		let a = helperXor1 res
		    b = helperXor2 res
		    res = Tagged $ (genSeedLength `for` a) + (genSeedLength `for` b)
		in res
	genBytes req (GenXor a b) = do
		(r1, a') <- genBytes req a
		(r2, b') <- genBytes req b
		return (zwp' r1 r2, GenXor a' b')
	genBytesWithEntropy req ent (GenXor a b) = do
		(r1, a') <- genBytesWithEntropy req ent a
		(r2, b') <- genBytesWithEntropy req ent b
		return (zwp' r1 r2, GenXor a' b')
	reseed ent (GenXor a b) = do
		let (b1, b2) = B.splitAt (genSeedLength `for` a) ent
		a' <- reseed b1 a
		b' <- reseed b2 b
		return (GenXor a' b')

-- |@g :: GenBuffered a@ is a generator of type @a@ that attempts to
-- maintain a buffer of random values size > 1MB and < 5MB at any time.
--
-- Because of the way in which the buffer is computed (at idle times) and
-- information on the previous generator is lost, it basically is not possible
-- to reseed this generator after a GenError.
data GenBuffered g = GenBuffered (Either GenError (B.ByteString, g)) {-# UNPACK #-} !B.ByteString

proxyToGenBuffered :: Proxy g -> Proxy (Either GenError (GenBuffered g))
proxyToGenBuffered = const Proxy

bufferMinSize = 2^20
bufferMaxSize = 2^22

instance (CryptoRandomGen g) => CryptoRandomGen (GenBuffered g) where
	{-# SPECIALIZE instance CryptoRandomGen (GenBuffered HmacDRBG) #-}
	newGen bs = do
		g <- newGen bs
		(rs,g') <- genBytes bufferMinSize g
		let new = genBytes bufferMinSize g'
		return (GenBuffered new rs)
	genSeedLength =
		let a = help res
		    res = Tagged $ genSeedLength `for` a
		in res
	  where
	  help :: Tagged (GenBuffered g) c -> g
	  help = const undefined
	genBytes req gb@(GenBuffered g bs)
		| remSize >= bufferMinSize =  Right (B.take req bs, GenBuffered g (B.drop req bs))
		| B.length bs < bufferMinSize =
			case g of
				Left err  -> Left err
				Right g   -> Left (GenErrorOther "Buffering generator failed to buffer properly - unknown reason")
		| req > B.length bs = Left RequestedTooManyBytes
		| remSize < bufferMinSize =
			case g of
				Left err -> Left err -- We could satisfy _this_ request and fail after the buffer runs out, but why bother?
				Right (rnd, gen) ->
					let new = genBytes bufferMinSize gen
					in (eval new) `par` (genBytes req (GenBuffered new (B.append bs rnd)))
		| otherwise = Left $ GenErrorOther "Buffering generator hit an impossible case.  Please inform DRBG maintainer"
	  where
	  remSize = B.length bs - req
	genBytesWithEntropy req ent g = reseed ent g >>= \gen -> genBytes req gen
	reseed ent (GenBuffered g bs) = do
		(rs, g') <- g
		g'' <- reseed ent g'
		let new = genBytes bufferMinSize g''
		    bs' = B.take bufferMaxSize (B.append bs rs)
		return (GenBuffered new bs')

eval :: Either x (B.ByteString, g) -> Either x (B.ByteString, g)
eval (Left x) = Left x
eval (Right (g,bs)) = bs `seq` (g `seq` (Right (g, bs)))

-- |Not that it belongs here, or that it is technically correct as an instance of 'CryptoRandomGen', but simply because
-- it's a reasonable engineering choice here is a 'GenSystemRandom' that streams the system randoms. Take note:
-- 
--  * It uses the default definition of 'genByteWithEntropy'
--
--  * 'newGen' will always fail!  DO NOT USE 'newGenIO' for this generator!
--
--  * 'reseed' will always fail!
--
--  * the handle to the system random is never closed
data GenSystemRandom = GenSysRandom L.ByteString

getGenSystemRandom :: IO GenSystemRandom
getGenSystemRandom = do
	ch <- openHandle
	let getBS = unsafeInterleaveIO $ do
		bs <- hGetEntropy ch ((2^15) - 16)
		more <- getBS
		return (bs:more)
	liftM (GenSysRandom . L.fromChunks) getBS

instance CryptoRandomGen GenSystemRandom where
	newGen _ = Left $ GenErrorOther "SystemRandomGen isn't a semantically correct generator.  Tell your developer to use 'Crypto.Random.DRBG.getGenSystemRandom' instead of 'Crypto.Random.newGen'"
	genSeedLength = Tagged 0
	genBytes req (GenSysRandom bs) =
		let reqI = fromIntegral req
		    rnd = L.take reqI bs
		    rest = L.drop reqI bs
		in if L.length rnd == reqI
			then Right (B.concat $ L.toChunks rnd, GenSysRandom rest)
			else Left $ GenErrorOther "Error obtaining enough bytes from system random for given request"
	reseed _ _ = Left $ GenErrorOther "SystemRandomGen isn't a semantically correct generator. Don't use 'WithEntropy'."

-- |zipWith xor + Pack
-- As a result of rewrite rules, this should automatically be optimized (at compile time) 
-- to use the bytestring libraries 'zipWith'' function.
zwp' a = B.pack . B.zipWith xor a