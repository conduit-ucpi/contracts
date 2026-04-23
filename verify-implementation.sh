#!/bin/bash

  # Set your environment variables
  NETWORK_RPC_URL="https://mainnet.base.org"
  VERIFIER_URL="https://base.blockscout.com/api"
  IMPLEMENTATION_ADDRESS="0x0a9cC884C36Da6643c29d7fb31CF8CC52c181D1a"

  # Verify the implementation contract
  forge verify-contract \
      $IMPLEMENTATION_ADDRESS \
      src/EscrowContract.sol:EscrowContract \
      --verifier blockscout \
      --verifier-url $VERIFIER_URL \
      --compiler-version 0.8.26 \
      --num-of-optimizations 200 \
      --evm-version cancun \
      --watch
