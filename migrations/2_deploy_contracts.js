var EtherDollar = artifacts.require('EtherDollar.sol');
var Erc20Bank = artifacts.require('Erc20Bank.sol');
var Oracles = artifacts.require('Oracles.sol');
var Liquidator = artifacts.require('Liquidator.sol');

module.exports = function (deployer) {
  deployer.then(async () => {

    await deployer.deploy(EtherDollar);
    const instanceEtherDollar = await EtherDollar.deployed();

    await deployer.deploy(Erc20Bank, instanceEtherDollar.address);
    const instanceErc20Bank = await Erc20Bank.deployed();

    await instanceEtherDollar.transferOwnership(instanceErc20Bank.address);

    await deployer.deploy(Oracles, instanceErc20Bank.address);
    const instanceOracles = await Oracles.deployed();

    await deployer.deploy(Liquidator, instanceEtherDollar.address, instanceErc20Bank.address);
    const instanceLiquidator = await Liquidator.deployed();

    await instanceErc20Bank.setLiquidator(instanceLiquidator.address);
    await instanceErc20Bank.setOracle(instanceOracles.address);
  })
}
