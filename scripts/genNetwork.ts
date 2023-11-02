import { Wallet, ethers } from "ethers";
import { setupNetworks, config, getSigner } from "../test-ts/testSetup";
import * as fs from "fs";

async function main() {
  const ethProvider = new ethers.providers.JsonRpcProvider(config.ethUrl);
  const arbProvider = new ethers.providers.JsonRpcProvider(config.arbUrl);

  const ethDeployer = getSigner(ethProvider, config.ethKey);
  console.log(await ethDeployer.getBalance());
  console.log(
    await new Wallet(
      "cb5790da63720727af975f42c79f69918580209889225fa7128c92402a6d3a65"
    ).getBalance()
  );
  const arbDeployer = getSigner(arbProvider, config.arbKey);

  const { l1Network, l2Network } = await setupNetworks(
    ethDeployer,
    arbDeployer,
    config.ethUrl,
    config.arbUrl
  );

  fs.writeFileSync("./files/local/network.json", JSON.stringify({ l1Network, l2Network }, null, 2));
  console.log("network.json updated");
}

main().then(() => console.log("Done."));
