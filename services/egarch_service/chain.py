"""
Thin web3.py wrapper for interacting with deployed contracts.
ABIs are hardcoded (only the functions the service actually calls).
"""

from __future__ import annotations

import logging

from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

from . import config

logger = logging.getLogger(__name__)

_ORACLE_ABI = [
    {"name": "submitVolatility", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "volBPS", "type": "uint256"}], "outputs": []},
    {"name": "isHealthy", "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "bool"}]},
    {"name": "smoothedVolBPS", "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint256"}]},
]

_ENGINE_ABI = [
    {"name": "hasPending", "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "bool"}]},
    {"name": "currentMCR", "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint256"}]},
    {"name": "proposeMCRUpdate", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "spDepthBPS", "type": "uint256"},
                {"name": "tcrBPS", "type": "uint256"},
                {"name": "btcPrice", "type": "uint256"}], "outputs": []},
    {"name": "applyPendingProposal", "type": "function", "stateMutability": "nonpayable",
     "inputs": [], "outputs": []},
]

_ADAPTER_ABI = [
    {"name": "setSimulatedBTCPrice", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "price", "type": "uint256"}], "outputs": []},
    {"name": "getSystemStats", "type": "function", "stateMutability": "view",
     "inputs": [], "outputs": [{"name": "tcrBPS", "type": "uint256"},
                                {"name": "spDepthBPS", "type": "uint256"},
                                {"name": "btcPriceBPS", "type": "uint256"}]},
]


def connect() -> Web3:
    w3 = Web3(Web3.HTTPProvider(config.RPC_URL))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    if not w3.is_connected():
        raise ConnectionError(f"Cannot connect to {config.RPC_URL}")
    logger.info("Connected to chain *** (chainId=%s)", w3.eth.chain_id)
    return w3


def get_oracle(w3: Web3):
    return w3.eth.contract(
        address=Web3.to_checksum_address(config.ORACLE_ADDRESS),
        abi=_ORACLE_ABI,
    )


def get_engine(w3: Web3):
    return w3.eth.contract(
        address=Web3.to_checksum_address(config.ENGINE_ADDRESS),
        abi=_ENGINE_ABI,
    )


def get_adapter(w3: Web3):
    return w3.eth.contract(
        address=Web3.to_checksum_address(config.ADAPTER_ADDRESS),
        abi=_ADAPTER_ABI,
    )


def send_tx(w3: Web3, fn, gas: int = 300_000) -> str:
    """Build, sign, and broadcast a contract transaction. Returns tx hash."""
    account = w3.eth.account.from_key(config.PRIVATE_KEY)
    nonce   = w3.eth.get_transaction_count(account.address)
    tx = fn.build_transaction({
        "from":     account.address,
        "nonce":    nonce,
        "gas":      gas,
        "gasPrice": w3.eth.gas_price,
        "chainId":  w3.eth.chain_id,
    })
    signed = w3.eth.account.sign_transaction(tx, config.PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    if receipt["status"] != 1:
        raise RuntimeError(f"Transaction reverted: {tx_hash.hex()}")
    logger.info("TX confirmed: %s (gas used: %s)", tx_hash.hex(), receipt["gasUsed"])
    return tx_hash.hex()
