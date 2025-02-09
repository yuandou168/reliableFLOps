from brownie import compile_source

def compile_contracts():
    with open("contracts/FLIncentiveOptimized.sol") as f:
        incentive_code = f.read()
    
    with open("contracts/FLConsensus.sol") as f:
        consensus_code = f.read()
    
    incentive_contract = compile_source(incentive_code)['FLIncentiveOptimized']
    consensus_contract = compile_source(consensus_code)['FLConsensus']
    
    return incentive_contract, consensus_contract

if __name__ == "__main__":
    incentive, consensus = compile_contracts()
    print(f"Incentive ABI: {incentive.abi}")
    print(f"Consensus ABI: {consensus.abi}")