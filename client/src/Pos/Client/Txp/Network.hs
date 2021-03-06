{-# LANGUAGE RankNTypes   #-}
{-# LANGUAGE TypeFamilies #-}

-- | Functions for operating with transactions

module Pos.Client.Txp.Network
       ( TxMode
       , prepareMTx
       , prepareRedemptionTx
       , submitTxRaw
       , sendTxOuts
       ) where

import           Universum

import           Formatting (build, sformat, (%))
import           Mockable (MonadMockable)
import           System.Wlog (logInfo)

import           Pos.Client.Txp.Addresses (MonadAddresses (..))
import           Pos.Client.Txp.Balances (MonadBalances (..), getOwnUtxo)
import           Pos.Client.Txp.History (MonadTxHistory (..))
import           Pos.Client.Txp.Util (InputSelectionPolicy, PendingAddresses (..), TxCreateMode,
                                      TxError (..), createMTx, createRedemptionTx)
import           Pos.Communication.Message ()
import           Pos.Communication.Types (InvOrDataTK)
import           Pos.Core (Address, Coin, makeRedeemAddress, mkCoin, unsafeAddCoin, sealCurrency)
import           Pos.Core.Txp (TxAux (..), TxId, TxOut (..), TxOutAux (..), txaF)
import           Pos.Crypto (ProtocolMagic, RedeemSecretKey, SafeSigner, hash, redeemToPublic)
import           Pos.Infra.Communication.Protocol (OutSpecs)
import           Pos.Infra.Communication.Specs (createOutSpecs)
import           Pos.Infra.Diffusion.Types (Diffusion (sendTx))
import           Pos.Txp.Network.Types (TxMsgContents (..))
import           Pos.Txp.Toil.Types (filterUtxoByCurrency)
import           Pos.Util.Util (eitherToThrow)
import           Pos.WorkMode.Class (MinWorkMode)

type TxMode m
    = ( MinWorkMode m
      , MonadBalances m
      , MonadTxHistory m
      , MonadMockable m
      , MonadMask m
      , MonadThrow m
      , TxCreateMode m
      )

-- | Construct Tx using multiple secret keys and given list of desired outputs.
prepareMTx
    :: TxMode m
    => ProtocolMagic
    -> (Address -> Maybe SafeSigner)
    -> PendingAddresses
    -> InputSelectionPolicy
    -> NonEmpty Address
    -> NonEmpty TxOutAux
    -> AddrData m
    -> m (TxAux, NonEmpty TxOut)
prepareMTx pm hdwSigners pendingAddrs inputSelectionPolicy addrs outputs addrData = do
    utxo <- getOwnUtxos (toList addrs) -- TODO filter utxo by seal currency
    let sealUtxo = filterUtxoByCurrency utxo sealCurrency
    eitherToThrow =<< createMTx pm pendingAddrs inputSelectionPolicy sealUtxo hdwSigners outputs addrData

-- | Construct redemption Tx using redemption secret key and a output address
prepareRedemptionTx
    :: TxMode m
    => ProtocolMagic
    -> RedeemSecretKey
    -> Address
    -> m (TxAux, Address, Coin)
prepareRedemptionTx pm rsk output = do
    let redeemAddress = makeRedeemAddress $ redeemToPublic rsk
    utxo <- getOwnUtxo redeemAddress
    let sealUtxo = filterUtxoByCurrency utxo sealCurrency
    let addCoin c = unsafeAddCoin c . txOutValue . toaOut
        redeemBalance = foldl' addCoin (mkCoin 0) sealUtxo
        txOuts = one $
            TxOutAux {toaOut = TxOut output sealCurrency redeemBalance}
    when (redeemBalance == mkCoin 0) $ throwM RedemptionDepleted
    txAux <- eitherToThrow =<< createRedemptionTx pm sealUtxo rsk txOuts
    pure (txAux, redeemAddress, redeemBalance)

-- | Send the ready-to-use transaction
submitTxRaw
    :: (MinWorkMode m)
    => Diffusion m -> TxAux -> m Bool
submitTxRaw diffusion txAux@TxAux {..} = do
    let txId = hash taTx
    logInfo $ sformat ("Submitting transaction: "%txaF) txAux
    logInfo $ sformat ("Transaction id: "%build) txId
    sendTx diffusion txAux

sendTxOuts :: OutSpecs
sendTxOuts = createOutSpecs (Proxy :: Proxy (InvOrDataTK TxId TxMsgContents))
