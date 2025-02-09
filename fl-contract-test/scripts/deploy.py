# scripts/deploy.py
from brownie import FLIncentiveOptimized, FLConsensus, accounts, config

def main():
    # 加载账户
    deployer = accounts[0]
    
    # 部署激励合约
    print("🚀 部署激励合约...")
    incentive = FLIncentiveOptimized.deploy(
        3600,  # deadline (1 hour)
        600,   # grace period (10 mins)
        86400, # claim window (1 day)
        [[str(1e17)]*3]*3,  # stake matrix (0.1 ETH)
        [[100]*3]*3,        # multiplier matrix
        {'from': deployer, 'value': str(1e18)}  # 初始资金1 ETH
    )
    print(f"📄 激励合约地址: {incentive.address}")
    
    # 部署共识合约
    print("🚀 部署共识合约...")
    consensus = FLConsensus.deploy(
        incentive.address,
        3,  # min participants
        300, # model timeout (5 mins)
        {'from': deployer}
    )
    print(f"📄 共识合约地址: {consensus.address}")
    
    return incentive, consensus