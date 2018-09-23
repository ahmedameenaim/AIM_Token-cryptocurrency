var AIMToken = artifacts.require("./AIMToken.sol");

module.exports = function(deployer, network, accounts) {

  if(network === "development") {
    deployer.deploy(AIMToken, {from: accounts[0]});
  } else{
    deployer.deploy(AIMToken);
  }
  
};