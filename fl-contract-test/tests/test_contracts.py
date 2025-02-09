import pytest
from brownie import accounts, FLIncentiveOptimized, FLConsensus

@pytest.fixture
def incentive_contract():
    return accounts[0].deploy(
        FLIncentiveOptimized,
        3600,  # deadline (1 hour)
        600,   # grace period (10 mins)
        86400, # claim window (1 day)
        [[str(1e17)]*3]*3,  # stake matrix (0.1 ETH)
        [[100]*3]*3,        # multiplier matrix
        {'value': str(1e18)}  # 初始资金1 ETH
    )

@pytest.fixture
def consensus_contract(incentive_contract):
    return accounts[0].deploy(
        FLConsensus,
        incentive_contract.address,
        3,  # min participants
        300, # model timeout (5 mins)
    )

def test_participant_join(incentive_contract):
    """测试参与者加入"""
    user = accounts[1]
    stake_amount = incentive_contract.stakeMatrix(0,0)
    
    # 正确加入
    tx = incentive_contract.join(0, 0, {'from': user, 'value': stake_amount})
    assert incentive_contract.participants(user).joined()
    
    # 检查事件日志
    assert len(tx.events) == 1
    assert tx.events["ParticipantJoined"]["user"] == user.address

def test_fl_round_lifecycle(consensus_contract, incentive_contract):
    """测试FL轮次生命周期"""
    # 完成激励阶段
    incentive_contract.finalize({'from': accounts[0]})
    
    # 启动FL轮次
    tx = consensus_contract.startFLRound({'from': accounts[0]})
    assert consensus_contract.flRound() == 1
    
    # 检查事件
    assert len(tx.events) == 1
    assert tx.events["FLStarted"]["round"] == 1