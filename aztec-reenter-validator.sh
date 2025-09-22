#!/usr/bin/env bash
set -euo pipefail

# aztec-reenter-validator.sh
# 1) Extract BLS keys from Aztec tx input data
# 2) Call reenterExitedValidator(...) on the StakingAssetHandler contract

DEFAULT_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
VALIDATOR_CONTRACT="0x3743c7Bf782260824f62e759677d7C63FfE42c52"
ETHERS_VERSION="6.7.1"

echored()    { printf "\e[31m%s\e[0m
" "$*"; }
echogreen()  { printf "\e[32m%s\e[0m
" "$*"; }
echoyellow() { printf "\e[33m%s\e[0m
" "$*"; }

echo "=============================================="
echo " Aztec validator re-entry helper"
echo "=============================================="
echo
echo "This script will extract BLS keys from Aztec tx data and"
echo "submit reenterExitedValidator(...) to the StakingAssetHandler contract."
echo
echo "You will be asked for:"
echo " - the raw tx input (without 0x)"
echo " - an optional validator address (if extraction fails)"
echo " - your private key (used to sign the transaction)"
echo
read -rp "Enter RPC URL to use (press Enter for default): " USER_RPC
RPC_URL="${USER_RPC:-$DEFAULT_RPC_URL}"
echo "Using RPC: $RPC_URL"
echo

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---- Extract keys JS ----
cat > "$TMPDIR/extract-keys.js" <<'JS'
function extract(data, startIndex) {
  return data.substring(startIndex, Math.min(startIndex + 64, data.length));
}
try {
  const input = (process.argv[2] || "").trim();
  const manualValidator = (process.argv[3] || "").trim();
  if (!input) {
    console.error("ERROR: No input tx data provided on command line.");
    process.exit(2);
  }
  const clean = input.startsWith("0x") ? input.slice(2) : input;
  const fallback = {
    validator_address: manualValidator || "0x0000000000000000000000000000000000000000",
    g1_x: "5588408605609299681954726477076967825869339953541418663948878911572890216306",
    g1_y: "3700044002884177515203365178827804490820874601472823530555383777103344024852",
    g2_x0: "67571070718862972900630456611179059396484084741944394516640002325435084094632",
    g2_x1: "66782943625003927866987625816210101847868984175367444724343782999305282400195",
    g2_y0: "69151396125685302578005768736764792105793506622201171735049657449349449363612",
    g2_y1: "69151396125685302578005768736801265736539722210212685575384717551234300769348",
    sig_x: "93638452037056450537683218137183499197263934447738550729524242403325229921348",
    sig_y: "74162737112043281483032011969436294322994565333032163808003452994977123265239"
  };
  const proofData_start = 1292, pubInputs_start = 18860;
  let proofData_hex = "";
  if (clean.length > proofData_start) proofData_hex = clean.substring(proofData_start);
  let pubInputs_hex = "";
  if (proofData_hex.length > pubInputs_start) pubInputs_hex = proofData_hex.substring(pubInputs_start);
  try {
    if(pubInputs_hex.length === 0) throw new Error("pubInputs data is empty");
    const validator_hex = extract(pubInputs_hex, 2068);
    const validator_address = "0x" + validator_hex.slice(-40) || fallback.validator_address;
    const g1_x = "0x" + extract(pubInputs_hex, 16);
    const g1_y = "0x" + extract(pubInputs_hex, 80);
    const g2_x0 = "0x" + extract(pubInputs_hex, 248);
    const g2_x1 = "0x" + extract(pubInputs_hex, 184);
    const g2_y0 = "0x" + extract(pubInputs_hex, 440);
    const g2_y1 = "0x" + extract(pubInputs_hex, 376);
    const sig_x = "0x" + extract(pubInputs_hex, 312);
    const sig_y = "0x" + extract(pubInputs_hex, 504);
    const hexes = [g1_x, g1_y, g2_x0, g2_x1, g2_y0, g2_y1, sig_x, sig_y];
    const ok = hexes.every(h => /^0x[0-9a-fA-F]{64}$/.test(h));
    if(!ok){ throw new Error("Extracted items not all valid 32-byte hex values"); }
    const out = {
      validator_address: validator_address,
      g1_x: BigInt(g1_x).toString(),
      g1_y: BigInt(g1_y).toString(),
      g2_x0: BigInt(g2_x0).toString(),
      g2_x1: BigInt(g2_x1).toString(),
      g2_y0: BigInt(g2_y0).toString(),
      g2_y1: BigInt(g2_y1).toString(),
      sig_x: BigInt(sig_x).toString(),
      sig_y: BigInt(sig_y).toString()
    };
    console.log(JSON.stringify(out));
    console.error("✅ Extraction successful.");
  } catch (e) {
    const out = fallback;
    console.log(JSON.stringify(out));
    console.error("⚠️ Extraction fallback: " + e.message);
  }
} catch (err) {
  console.error("Fatal extraction error:", err.message, err);
  process.exit(3);
}
JS

# ---- Write register.js ----
cat > "$TMPDIR/register.js" <<'JS'
const fs = require('fs');
const { ethers } = require('ethers');

if (process.argv.length < 3) {
  console.error("Usage: node register.js <keys.json> [privateKey] [rpcUrl]");
  process.exit(2);
}

const keysPath = process.argv[2];
const privateKey = process.argv[3] || "";
const rpcUrl = process.argv[4] || "https://ethereum-sepolia-rpc.publicnode.com";

const VALIDATOR_CONTRACT = "0x3743c7Bf782260824f62e759677d7C63FfE42c52";
const abi = [{
  "inputs":[
    {"internalType":"address","name":"_attester","type":"address"},
    {"components":[{"internalType":"uint256","name":"x","type":"uint256"},{"internalType":"uint256","name":"y","type":"uint256"}],"internalType":"struct G1Point","name":"_publicKeyG1","type":"tuple"},
    {"components":[{"internalType":"uint256","name":"x0","type":"uint256"},{"internalType":"uint256","name":"x1","type":"uint256"},{"internalType":"uint256","name":"y0","type":"uint256"},{"internalType":"uint256","name":"y1","type":"uint256"}],"internalType":"struct G2Point","name":"_publicKeyG2","type":"tuple"},
    {"components":[{"internalType":"uint256","name":"x","type":"uint256"},{"internalType":"uint256","name":"y","type":"uint256"}],"internalType":"struct G1Point","name":"_signature","type":"tuple"}
  ],
  "name":"reenterExitedValidator","outputs":[],"stateMutability":"nonpayable","type":"function"
}];

try {
  const raw = fs.readFileSync(keysPath, 'utf8');
  const keys = JSON.parse(raw);
  if (!privateKey) {
    console.error("Private key not supplied as CLI arg");
    process.exit(3);
  }
  (async () => {
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey, provider);
    const contract = new ethers.Contract(VALIDATOR_CONTRACT, abi, wallet);
    const attester = keys.validator_address;
    const g1 = { x: BigInt(keys.g1_x), y: BigInt(keys.g1_y) };
    const g2 = { x0: BigInt(keys.g2_x0), x1: BigInt(keys.g2_x1), y0: BigInt(keys.g2_y0), y1: BigInt(keys.g2_y1) };
    const signature = { x: BigInt(keys.sig_x), y: BigInt(keys.sig_y) };
    console.error("Submitting reenterExitedValidator with attester", attester);
    try {
      const tx = await contract.reenterExitedValidator(attester, g1, g2, signature, { gasLimit: 2_000_000n });
      console.error("Submitted tx:", tx.hash);
      const receipt = await tx.wait();
      console.error("Tx confirmed in block", receipt.blockNumber.toString());
      console.error("Gas used:", receipt.gasUsed.toString());
    } catch (txErr) {
      console.error("Transaction failed:", txErr.message, txErr);
      if (txErr.data) console.error("Contract error data:", txErr.data);
      process.exit(4);
    }
  })();
} catch (e) {
  console.error("Failed to load or parse keys.json:", e.message, e);
  process.exit(1);
}
JS

# ---- Install Node + ethers.js if needed ----
if ! command -v node >/dev/null 2>&1; then
  echoyellow "Node.js not found. Installing minimal Node (from package manager)..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y nodejs npm
  else
    echored "Please install Node.js (v18+) before running this script."
    exit 1
  fi
fi

cd "$TMPDIR"
npm init -y >/dev/null 2>&1
echogreen "Installing ethers@${ETHERS_VERSION} (this may take a minute)..."
npm install "ethers@${ETHERS_VERSION}" >/dev/null 2>&1

echo
echoyellow "Paste the raw tx input data (HEX) here (without 0x). End with ENTER:"
read -r TXDATA
echo
read -rp "Optional: validator address (0x...) to force if extraction fails (or press Enter): " MANUAL_VALIDATOR

KEYS_JSON_FILE="$TMPDIR/keys.json"
node "$TMPDIR/extract-keys.js" "$TXDATA" "$MANUAL_VALIDATOR" > "$KEYS_JSON_FILE" 2>/dev/tty

echo
echoyellow "Keys saved to: $KEYS_JSON_FILE"
cat "$KEYS_JSON_FILE"

echo
echoyellow "Enter the private key for the wallet you will use to call reenterExitedValidator (no 0x):"
read -rp "> " PKEY
echo
if [[ ! "$PKEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echored "Warning: private key format looks unusual. Press Ctrl-C to abort if this is wrong."
  sleep 2
fi

echogreen "Running registration script now (this will broadcast a tx)."
node "$TMPDIR/register.js" "$KEYS_JSON_FILE" "$PKEY" "$RPC_URL"

echogreen "Done. Temporary files will be cleaned up on exit."
echo
echoyellow "Script finished. Press Enter to exit."
read -r