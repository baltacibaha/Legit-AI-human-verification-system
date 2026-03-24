'use strict';

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });

const { EASService, LEGIT_SCHEMA_DEFINITION } = require('../easService');

async function main () {
  console.log('Deploying LEGIT schema to EAS…');
  console.log('Schema:', LEGIT_SCHEMA_DEFINITION);
  console.log('Network:', process.env.EAS_NETWORK || 'sepolia');

  if (!process.env.EAS_PRIVATE_KEY || !process.env.EAS_RPC_URL) {
    console.error('ERROR: EAS_PRIVATE_KEY and EAS_RPC_URL must be set in .env');
    process.exit(1);
  }

  const service = new EASService();

  let health;
  try {
    health = await service.getNetworkHealth();
    console.log('\nWallet health:');
    console.log('  Address:    ', health.signerAddress);
    console.log('  Balance:    ', health.balanceEth, 'ETH');
    console.log('  Gas price:  ', health.gasPriceGwei, 'gwei');
    console.log('  Network:    ', health.network);
  } catch (err) {
    console.error('Could not fetch network health:', err.message);
    process.exit(1);
  }

  if (!health.healthy) {
    console.error('\nERROR: Wallet balance too low. Top up the wallet and retry.');
    process.exit(1);
  }

  let result;
  try {
    result = await service.deploySchema(true);
  } catch (err) {
    console.error('\nSchema deployment failed:', err.message);
    if (err.cause) console.error('Cause:', err.cause.message);
    process.exit(1);
  }

  console.log('\n✓ Schema deployed successfully!');
  console.log('  Schema UID:', result.schemaUID);
  console.log('  Tx hash:   ', result.txHash);
  console.log('\nAdd this to your .env:');
  console.log(`  EAS_SCHEMA_UID=${result.schemaUID}`);
}

main().catch(err => { console.error('Unhandled error:', err); process.exit(1); });
