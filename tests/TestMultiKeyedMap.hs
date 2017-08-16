{-# LANGUAGE OverloadedStrings, TemplateHaskell, QuasiQuotes, NamedFieldPuns, ViewPatterns, NoImplicitPrelude #-}
module TestMultiKeyedMap (tests) where

import Protolude hiding (keys)
import qualified Data.Map as Map
import qualified Data.List as List
import Test.Tasty (TestTree)
import Test.Tasty.TH
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import qualified Data.MultiKeyedMap as MKM

emptyMkm :: (Ord k) => MKM.MKMap k v
emptyMkm = MKM.mkMKMap (Proxy :: Proxy Int)

prop_equality :: Property
prop_equality =
  forAll (resize 5 arbitrary :: Gen [([Int], Int)])
    $ \map1 -> forAll (resize 4 arbitrary :: Gen [([Int], Int)])
    $ \map2 ->
        -- equality of contents also applies to the MKM
        (map1 == map2) === (fromList map1 == fromList map2)
        -- force the contents to be the same, should always be equal
  where
    fromList = MKM.fromList (Proxy :: Proxy Int)

-- | inserting the same value is idempotent
prop_insertIdempotent :: Int -> Int -> Property
prop_insertIdempotent key val = do
  let insVal = MKM.insert key val
  (insVal emptyMkm) === (insVal (insVal emptyMkm))

-- | inserting the same values in a different order
-- results in the same map
prop_insertShuffled :: [(Int, Int)] -> Property
prop_insertShuffled xs =
  let xs' = List.nubBy ((==) `on` fst) xs
      insVals = foldl' (\m (k, v) -> MKM.insert k v m) emptyMkm
  in forAll (shuffle xs')
    $ \ys -> insVals xs' === insVals ys

tests :: TestTree
tests = $(testGroupGenerator)