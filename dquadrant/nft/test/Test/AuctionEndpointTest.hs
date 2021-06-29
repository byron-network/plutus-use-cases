{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores#-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
module Test.AuctionEndpointTest
(tests)
where

import Test.TestHelper
import Ledger.Ada ( lovelaceValueOf )
import Ledger.Value as Value ( geq )
import Plutus.Contract.Test
import PlutusTx.Prelude hiding (Eq((==)))
import Test.Tasty
import Plutus.Contract.Wallet.EndpointModels hiding(value)
import Plutus.Trace.Emulator
import Ledger.TimeSlot (slotToPOSIXTime)
import Ledger hiding(singleton)
import Prelude (show, Eq ((==)))
import Data.Functor
import qualified Data.Aeson.Types as AesonTypes
import Data.Text (Text)


tests :: TestTree
tests = testGroup "Auction"
      [ 
      canPlaceOnAuction,
      canQueryOwnAndOthersAuction,
      canBidOnAuction,
      canWithdrawFromAuction,
      whenBid'previousBidderReceivesOldBidAmount,

      -- when winner claims
      whenWin'canClaimAuction,
      whenClaimAuctionByWinner'operatorReceivesFee,
      whenClaimAuctionByWinner'sellerReceivesPayment,

      -- when seller claims
      whenClaimAuctionBySeller'buyerReceivesAsset,
      whenClaimAuctionBySeller'sellerReceivesPayment,
      whenClaimAuctionBySeller'operatorReceivesFee ]

defaultAuctionParam :: Value -> AuctionParam
defaultAuctionParam _nft =AuctionParam{
            apValue=toValueInfo  _nft ,
            apMinBid=valueInfoLovelace 10_000_000,
            apMinIncrement=2_000_000,
            apStartTime=slotToPOSIXTime 10,
            apEndTime=slotToPOSIXTime 100
          }

defaultResponse :: TxOutRef ->ByteString-> AuctionResponse
defaultResponse utxoRef _nft= AuctionResponse{
    arOwner = pubKeyHash $ walletPubKey  $ Wallet 1,
      arValue = [ValueInfo _nft "" 1],
      arMinBid = ValueInfo "" "" 10_000_000,
      arMinIncrement = 2_000_000,
      arDuration =  (Finite (slotToPOSIXTime $ Slot 10) ,  Finite  (slotToPOSIXTime $ Slot 100) ),
      arBidder = Bidder{
                  bPubKeyHash   = pubKeyHash $ walletPubKey  $ Wallet 1,
                  bBid          = 0,
                  bBidReference =  utxoRef
              },
      arMarketFee = 1_000_000
    }

canPlaceOnAuction :: TestTree
canPlaceOnAuction=
    defaultCheck
    "CanPlace On Auction"
    (   walletFundsChange (Wallet 1) (negNft "aa")
      .&&. lockedByMarket (nft "aa")
    )$    do
      h1 <- getHandle 1
      callEndpoint @"startAuction" h1 [defaultAuctionParam (nft "aa")]
      utxos<-waitForLastUtxos h1
      doList h1 >>=expectSingleAuction (defaultResponse  (head utxos) "aa" )


canQueryOwnAndOthersAuction ::TestTree
canQueryOwnAndOthersAuction = defaultCheck
  "Can List Own Auction in Market"
  assertNoFailedTransactions
  $ do
    h1<-getHandle 1
    h2<- getHandle 2

    callEndpoint @"startAuction" h1 [defaultAuctionParam (nft "aa")]
    callEndpoint @"startAuction" h2 [defaultAuctionParam (nft "ba")]
    u1 <-waitForLastUtxos h1 <&> head
    u2 <-lastUtxos h2 <&> head
    doListOwn h1 >>= expectSingleAuction (defaultResponse u1 "aa")
    doListOfWallet 1 h2 >>= expectSingleAuction (defaultResponse u1 "aa")

    doListOwn h2 >>=expectSingleAuction (defaultResponse u2 "ba")
    doListOfWallet 2 h1 >>= expectSingleAuction (defaultResponse u2 "ba")

canWithdrawFromAuction ::TestTree
canWithdrawFromAuction=defaultCheck
  "Can Withdraw from Auction"
  (
    assertNoFailedTransactions
    .&&. lockedByMarket (noNft "aa")
    .&&. walletFundsChange (Wallet 2) (noNft "aa")
  )$ do
    h1<- getHandle 1
    defaultAuctionUtxo h1
      >>= doWithdraw h1
      >> wait

canBidOnAuction :: TestTree
canBidOnAuction=defaultCheck
    "Can bid on auction"
    (         assertNoFailedTransactions
        .&&.  lockedByMarket ( nft "aa" <> lovelaceValueOf 50_000_000)
        .&&.  walletFundsChange (Wallet 2) (lovelaceValueOf (-50_000_000))
    )$    do
      h1 <-getHandle 1
      h2 <-getHandle 2
      h3 <- getHandle 3
      bidUtxo<-defaultAuctionUtxo h1
          >>= doBid h2 15_000_000
          >>= doBid h3 30_000_000
          >>= doBid h2 50_000_000
          <&> head
      doListOwn h2 >>= expectSingleAuction (defaultResponse bidUtxo "aa")

whenBid'previousBidderReceivesOldBidAmount :: TestTree
whenBid'previousBidderReceivesOldBidAmount=
  defaultCheck
    "Last Bidder Receives its bid on new bid"
    (         assertNoFailedTransactions
        .&&.  walletFundsChange (Wallet 2) (lovelaceValueOf 0)
        .&&. walletFundsChange (Wallet 3) (lovelaceValueOf 0)
        .&&. walletFundsChange (Wallet 4) (lovelaceValueOf (-500_000_000))
    )$    do
      h1<- getHandle 1
      h2 <-getHandle 2
      h3 <- getHandle 3
      h4 <-getHandle 4

      void $
            defaultAuctionUtxo h1
        >>= doBid h4 10_000_000
        >>= doBid h3 20_000_000
        >>= doBid h2 30_000_000
        >>= doBid h4 50_000_000
        >>= doBid h3 100_000_000
        >>= doBid h4 500_000_000


whenWin'canClaimAuction :: TestTree
whenWin'canClaimAuction=
  defaultCheck
    "Bidder can claim auction after it's over"
    (         assertNoFailedTransactions
        .&&.  valueAtAddress (pubKeyAddress $ walletPubKey $ Wallet 3) (\v-> v `geq` nft "aa")
        .&&. lockedByMarket (lovelaceValueOf 0)
    )$    do
      h1 <- getHandle 1
      h2 <-getHandle 2
      h3 <- getHandle 3
      defaultAuctionUtxo h1
        >>=doBid h2 10_000_000
        >>=doBid h3 30_000_000
        >>=doClaim h3

whenClaimAuctionBySeller'buyerReceivesAsset :: TestTree
whenClaimAuctionBySeller'buyerReceivesAsset=
  defaultCheck
    "When Seller claims auction, buyer receives Asset"
    (   assertNoFailedTransactions
    .&&. walletHasAtLeast  (nft "aa") 2
    .&&. lockedByMarket (noNft "aa")
    )$    do
      h1 <- getHandle 1
      h2<-getHandle 2
      h3 <-getHandle 3
      defaultAuctionUtxo h1
        >>=doBid h2 100_000_000
        >>=doBid h3 200_000_000
        >>=doBid h2 300_000_000
        >>= doClaim h1

whenClaimAuctionByWinner'operatorReceivesFee :: TestTree
whenClaimAuctionByWinner'operatorReceivesFee=
  defaultCheck
    "When Winner claims auction, Operator Receives Fee"
    (         assertNoFailedTransactions
        .&&. walletFundsChange operator  (lovelaceValueOf 6_000_000)
    )$    do
      h1<- getHandle 1
      h2 <-getHandle 2
      h3<-getHandle 3
      defaultAuctionUtxo h1
        >>=doBid h2 100_000_000
        >>=doBid h3 200_000_000
        >>=doBid h2 600_000_000
        >>= doClaim h2

whenClaimAuctionBySeller'operatorReceivesFee :: TestTree
whenClaimAuctionBySeller'operatorReceivesFee=
  defaultCheck
    "When Seller claims auction, Operator Receives Fee"
    (         assertNoFailedTransactions
        .&&. walletFundsChange operator  (lovelaceValueOf 6_000_000)
    )$    do
      h1<- getHandle 1
      h2 <-getHandle 2
      h3<-getHandle 3
      defaultAuctionUtxo h1
        >>=doBid h2 100_000_000
        >>=doBid h3 200_000_000
        >>=doBid h2 600_000_000
        >>= doClaim h1

whenClaimAuctionByWinner'sellerReceivesPayment :: TestTree
whenClaimAuctionByWinner'sellerReceivesPayment=
  defaultCheck
    "When winner claims auction, Seller Receives Payment"
    (   assertNoFailedTransactions
    .&&.walletFundsChange (Wallet 1) (lovelaceValueOf 495_000_000 <> negNft "aa")
    )$    do
      h1 <- getHandle 1
      h2<-getHandle 2
      h3 <-getHandle 3
      defaultAuctionUtxo h1
        >>=doBid h2 100_000_000
        >>=doBid h3 300_000_000
        >>=doBid h2 500_000_000
        >>= doClaim h2

whenClaimAuctionBySeller'sellerReceivesPayment :: TestTree
whenClaimAuctionBySeller'sellerReceivesPayment=
  defaultCheck
    "When Seller Claims auction, Seller Receives Payment"
    (   assertNoFailedTransactions
    .&&.walletFundsChange (Wallet 1) (lovelaceValueOf 495_000_000 <> negNft "aa")
    )$    do
      h1 <- getHandle 1
      h2<-getHandle 2
      h3 <-getHandle 3
      defaultAuctionUtxo h1
        >>=doBid h2 100_000_000
        >>=doBid h3 300_000_000
        >>=doBid h2 500_000_000
        >>= doClaim h1

-- create the default auction and wait until it's starting period
defaultAuctionUtxo :: ContractHandle [AesonTypes.Value] TestSchema Text -> EmulatorTrace [TxOutRef]
defaultAuctionUtxo h =do
      callEndpoint @"startAuction" h [defaultAuctionParam (nft "aa")]
      u1<-waitForLastUtxos h
      void $ waitUntilSlot 10
      return  u1


-- bid on utxo and get the new utxo after transaction is confirmed
doBid:: ContractHandle [AesonTypes.Value] TestSchema Text -> Integer -> [TxOutRef]->EmulatorTrace [TxOutRef]
doBid h v u= do
  callEndpoint @"bid" h $ BidParam (head u) [valueInfoLovelace v]
  waitForLastUtxos h

-- claim an utxo and wait for it to get confirmed
doClaim:: ContractHandle [AesonTypes.Value] TestSchema Text -> [TxOutRef]->EmulatorTrace ()
doClaim h u = do
  void $ waitUntilSlot 100
  callEndpoint @"claim" h $ ClaimParam u True
  wait

-- withdraw an utxo
doWithdraw ::ContractHandle [AesonTypes.Value] TestSchema Text -> [TxOutRef] -> EmulatorTrace()
doWithdraw h u= callEndpoint @"withdraw" h  u >> wait

doList ::ContractHandle [AesonTypes.Value] TestSchema Text -> EmulatorTrace [AuctionResponse]
doList h= do
  callEndpoint @"list" h  (ListMarketRequest MtAuction Nothing  (Just False))
  wait
  lastResult h

doListOfWallet :: Integer -> ContractHandle [AesonTypes.Value] TestSchema Text -> EmulatorTrace [AuctionResponse]
doListOfWallet w h = do
  callEndpoint @"list" h  (ListMarketRequest MtAuction (Just $ getPubKeyHash  $ pubKeyHash $ walletPubKey$ Wallet w)  (Just False))
  wait
  lastResult h

doListOwn ::  ContractHandle [AesonTypes.Value] TestSchema Text -> EmulatorTrace [AuctionResponse]
doListOwn h = do
  callEndpoint @"list" h  (ListMarketRequest MtAuction Nothing (Just True))
  wait
  lastResult h

expectSingleAuction :: AuctionResponse -> [AuctionResponse]  -> EmulatorTrace ()
expectSingleAuction expected as =case as of
  [a] -> assertTrue "h1 Auction response mismatch" (a == expected)
  _   ->  throw $ "Expected single response with auction got: " ++ show as

