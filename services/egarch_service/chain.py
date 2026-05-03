"""
Thin web3.py wrapper for interacting with deployed contracts.
Loads ABI from Foundry's out/ directory automatically.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

from . import config

logger = logging.getLogger(__name__)


def _load_abi(contract_name: str) -> list[dict]:
    """Load ABI from Foundry build output."""
    abi_path = config.OUT_DIR / f"{contract_name}.sol" / f"{contract_name}.json"
    if not abi_path.exists():
        raise FileNotFoundError(
            f"ABI not found at {abi_path}. Run `forge build` first."
        )
    with open(abi_path) as f:
        artifact = json.load(f)
    return artifact["abi"]


def connect() -> Web3:
    w3 = Web3(Web3.HTTPProvider(config.RPC_URL))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    if not w3.is_connected():
        raise ConnectionError(f"Cannot connect to {config.RPC_URL}")
    logger.info("Connected to chain %s (chainId=%s)", config.RPC_URL, w3.eth.chain_id)
    return w3


def get_oracle(w3: Web3):
    return w3.eth.contract(
        address=Web3.to_checksum_address(config.ORACLE_ADDRESS),
        abi=_load_abi("VolatilityOracle"),
    )


def get_engine(w3: Web3):
    return w3.eth.contract(
        address=Web3.to_checksum_address(config.ENGINE_ADDRESS),
        abi=_load_abi("AdaptiveMCREngine"),
    )


def get_adapter(w3: Web3):
    return w3.eth.contract(
        address=Web3.to_checksum_address(config.ADAPTER_ADDRESS),
        abi=_load_abi("MezoIntegrationAdapter"),
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
