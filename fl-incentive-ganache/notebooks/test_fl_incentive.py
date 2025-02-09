from web3 import Web3
import pandas as pd
import matplotlib.pyplot as plt
from datetime import datetime, timedelta
import time
import json

# 连接Ganache
w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
print(f"连接状态: {w3.is_connected()}")

# 部署配置
compile_source = '''
// 这里插入优化后的完整合约代码
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract FLIncentiveOptimized {
    // 时间配置结构体
    struct TimeConfig {
        uint256 deadline;      // 注册截止时间
        uint256 gracePeriod;   // 宽限期（秒）
        uint256 claimWindow;   // 奖励领取窗口期（秒）
    }
    
    // 参与者数据结构
    struct Participant {
        uint8 dataCat;        // 数据类别 (0-2)
        uint8 resourceCat;    // 资源类别 (0-2)
        uint96 stakePaid;     // 已质押金额
        uint40 joinTime;      // 加入时间戳
        bool isRewarded;
        bool joined;
    }

    // 状态变量
    address public immutable publisher;
    TimeConfig public timeConfig;
    uint256 public totalLocked;
    
    // 参数矩阵
    uint96[3][3] public stakeMatrix;
    uint16[3][3] public multiplierMatrix;
    
    // 状态管理
    enum ContractPhase { ACTIVE, GRACE, CLOSED }
    ContractPhase public currentPhase;
    mapping(address => Participant) public participants;
    mapping(address => uint256) public pendingRewards;
    address[] public participantList;

    // 事件系统
    event ParticipantJoined(address indexed user, uint8 dataCat, uint8 resourceCat, uint256 stake);
    event ContractFinalized(uint256 totalRewards);
    event RewardClaimed(address indexed user, uint256 amount);
    event PhaseChanged(ContractPhase newPhase);
    event ParametersUpdated(uint8 indexed dcat, uint8 indexed rcat, uint256 newStake, uint256 newMultiplier);
    event LatePenaltyApplied(address indexed user, uint256 penalty);

    // 权限和条件校验modifier
    modifier onlyPublisher() {
        require(msg.sender == publisher, "Unauthorized");
        _;
    }

    modifier validCategories(uint8 dcat, uint8 rcat) {
        require(dcat <= 2 && rcat <= 2, "Invalid categories");
        _;
    }

    modifier inPhase(ContractPhase phase) {
        _updatePhase();
        require(currentPhase == phase, "Invalid phase");
        _;
    }

    constructor(
        uint256 _deadline,
        uint256 _gracePeriod,
        uint256 _claimWindow,
        uint96[3][3] memory _stakeMatrix,
        uint16[3][3] memory _multiplierMatrix
    ) payable {
        require(_deadline > block.timestamp, "Invalid deadline");
        require(_gracePeriod <= 7 days, "Grace period too long");
        
        publisher = msg.sender;
        timeConfig = TimeConfig(_deadline, _gracePeriod, _claimWindow);
        stakeMatrix = _stakeMatrix;
        multiplierMatrix = _multiplierMatrix;
        totalLocked = msg.value;
        
        _updatePhase();
    }

    // 核心功能函数
    function join(uint8 dcat, uint8 rcat) 
        external 
        payable 
        inPhase(ContractPhase.ACTIVE)
        validCategories(dcat, rcat)
    {
        require(!participants[msg.sender].joined, "Already joined");
        
        uint256 requiredStake = stakeMatrix[dcat][rcat];
        require(msg.value == requiredStake, "Incorrect stake");
        
        participants[msg.sender] = Participant({
            dataCat: dcat,
            resourceCat: rcat,
            stakePaid: uint96(msg.value),
            joinTime: uint40(block.timestamp),
            isRewarded: false,
            joined: true
        });
        
        participantList.push(msg.sender);
        totalLocked += msg.value;
        
        emit ParticipantJoined(msg.sender, dcat, rcat, msg.value);
    }

    function finalize() external onlyPublisher inPhase(ContractPhase.GRACE) {
        uint256 totalMultipliers;
        
        // 第一阶段：计算总乘数并应用延迟惩罚
        for (uint256 i = 0; i < participantList.length; i++) {
            address addr = participantList[i];
            Participant memory p = participants[addr];
            
            // 应用最后1小时加入的5%惩罚
            if (p.joinTime > timeConfig.deadline - 1 hours) {
                uint256 penalty = p.stakePaid * 5 / 100;
                participants[addr].stakePaid -= uint96(penalty);
                emit LatePenaltyApplied(addr, penalty);
            }
            
            totalMultipliers += multiplierMatrix[p.dataCat][p.resourceCat];
        }

        // 第二阶段：按比例分配奖励
        uint256 rewardPerPoint = address(this).balance / totalMultipliers;
        require(rewardPerPoint > 0, "Insufficient rewards");
        
        for (uint256 i = 0; i < participantList.length; i++) {
            address addr = participantList[i];
            Participant memory p = participants[addr];
            
            uint256 points = multiplierMatrix[p.dataCat][p.resourceCat];
            pendingRewards[addr] = rewardPerPoint * points;
        }

        _updatePhase();
        emit ContractFinalized(address(this).balance);
    }

    function claimReward() external inPhase(ContractPhase.CLOSED) {
        require(block.timestamp < timeConfig.deadline + 
                timeConfig.gracePeriod + 
                timeConfig.claimWindow, "Claim expired");
        
        Participant storage p = participants[msg.sender];
        require(p.joined, "Not participant");
        require(!p.isRewarded, "Already claimed");
        
        uint256 reward = pendingRewards[msg.sender];
        require(reward > 0, "No rewards");
        
        p.isRewarded = true;
        pendingRewards[msg.sender] = 0;
        
        (bool success, ) = msg.sender.call{value: reward}("");
        require(success, "Transfer failed");
        
        emit RewardClaimed(msg.sender, reward);
    }

    // 参数更新系统（带时间锁）
    uint256 public paramUpdateTime;
    uint8 public pendingDcat;
    uint8 public pendingRcat;
    uint96 public newStake;
    uint16 public newMultiplier;

    function requestParamUpdate(
        uint8 dcat,
        uint8 rcat,
        uint96 _stake,
        uint16 _multiplier
    ) external onlyPublisher validCategories(dcat, rcat) {
        paramUpdateTime = block.timestamp + 2 days;
        pendingDcat = dcat;
        pendingRcat = rcat;
        newStake = _stake;
        newMultiplier = _multiplier;
    }

    function confirmParamUpdate() external onlyPublisher {
        require(block.timestamp >= paramUpdateTime, "Timelock active");
        stakeMatrix[pendingDcat][pendingRcat] = newStake;
        multiplierMatrix[pendingDcat][pendingRcat] = newMultiplier;
        
        emit ParametersUpdated(pendingDcat, pendingRcat, newStake, newMultiplier);
    }

    // 资金管理函数
    function withdrawRemaining() external onlyPublisher {
        require(currentPhase == ContractPhase.CLOSED, "Not closed");
        require(block.timestamp > timeConfig.deadline + 
               timeConfig.gracePeriod + 
               timeConfig.claimWindow + 7 days, "Too early");
        
        uint256 balance = address(this).balance;
        (bool success, ) = publisher.call{value: balance}("");
        require(success, "Withdraw failed");
    }

    // 阶段管理内部函数
    function _updatePhase() internal {
        if (block.timestamp < timeConfig.deadline) {
            currentPhase = ContractPhase.ACTIVE;
        } else if (block.timestamp < timeConfig.deadline + timeConfig.gracePeriod) {
            currentPhase = ContractPhase.GRACE;
        } else {
            currentPhase = ContractPhase.CLOSED;
        }
        emit PhaseChanged(currentPhase);
    }

    // 视图函数
    function getParticipantCount() external view returns (uint256) {
        return participantList.length;
    }

    function currentPoolBalance() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        totalLocked += msg.value;
    }
}
'''

# 编译合约
compiled = compile_source(CONTRACT_SOURCE)
contract_id, contract_interface = compiled.popitem()
bytecode = contract_interface['bin']
abi = contract_interface['abi']

# 部署参数
INITIAL_ETH = Web3.to_wei(100, 'ether')
DEADLINE = int(time.time()) + 3600  # 1小时后截止
GRACE_PERIOD = 600                  # 10分钟宽限期
CLAIM_WINDOW = 86400                # 24小时领取期

# 部署合约
fl_contract = w3.eth.contract(abi=abi, bytecode=bytecode)
tx_hash = fl_contract.constructor(
    DEADLINE,
    GRACE_PERIOD,
    CLAIM_WINDOW,
    [
        [Web3.to_wei(1, 'ether'), Web3.to_wei(2, 'ether'), Web3.to_wei(3, 'ether')],
        [Web3.to_wei(1.5, 'ether'), Web3.to_wei(2.5, 'ether'), Web3.to_wei(3.5, 'ether')],
        [Web3.to_wei(2, 'ether'), Web3.to_wei(3, 'ether'), Web3.to_wei(4, 'ether')]
    ],
    [
        [1000, 1500, 2000],
        [1200, 1800, 2500],
        [1500, 2000, 3000]
    ]
).transact({
    'from': w3.eth.accounts[0],
    'value': INITIAL_ETH
})
tx_receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
contract_address = tx_receipt['contractAddress']
print(f"合约部署地址: {contract_address}")

# 加载合约实例
contract = w3.eth.contract(address=contract_address, abi=abi)

def set_time(target_timestamp):
    """设置区块链时间并挖矿"""
    w3.provider.make_request('evm_setNextBlockTimestamp', [target_timestamp])
    w3.provider.make_request('evm_mine', [])

def get_current_phase():
    """获取当前合约阶段"""
    phases = ['ACTIVE', 'GRACE', 'CLOSED']
    return phases[contract.functions.currentPhase().call()]

# 测试用例配置
test_cases = [
    # 正常注册测试
    {
        'name': '有效注册-低数据低资源',
        'dataCat': 0,
        'resourceCat': 0,
        'stake': 1.0,
        'time_offset': -300,  # 截止前5分钟
        'expected': 'success'
    },
    # 异常测试
    {
        'name': '无效资源类别',
        'dataCat': 0,
        'resourceCat': 3,
        'stake': 2.0,
        'time_offset': -300,
        'expected': 'revert'
    },
    # 延迟惩罚测试
    {
        'name': '最后1小时注册',
        'dataCat': 1,
        'resourceCat': 1,
        'stake': 2.5,
        'time_offset': -3500,  # 最后59分钟
        'expected': 'success+penalty'
    },
    # 阶段转换测试
    {
        'name': '宽限期操作',
        'action': 'finalize',
        'time_offset': 300,  # 截止后5分钟
        'expected': 'success'
    },
    # 奖励领取测试
    {
        'name': '正常领取奖励',
        'action': 'claim',
        'time_offset': 700,
        'expected': 'success'
    }
]

# 执行测试
results = []
for case in test_cases:
    # 设置时间
    target_time = DEADLINE + case['time_offset']
    set_time(target_time)
    
    # 执行操作
    try:
        if 'action' in case:
            if case['action'] == 'finalize':
                tx_hash = contract.functions.finalize().transact({'from': w3.eth.accounts[0]})
            elif case['action'] == 'claim':
                user = w3.eth.accounts[1]
                tx_hash = contract.functions.claimReward().transact({'from': user})
        else:
            user = w3.eth.accounts[len(results)+1]  # 使用不同账户
            stake_wei = Web3.to_wei(case['stake'], 'ether')
            tx_hash = contract.functions.join(
                case['dataCat'],
                case['resourceCat']
            ).transact({
                'from': user,
                'value': stake_wei
            })
        
        receipt = w3.eth.get_transaction_receipt(tx_hash)
        actual = 'success' if receipt.status else 'fail'
        
        # 检查惩罚应用
        if 'expected' in case and 'penalty' in case['expected']:
            penalty_events = contract.events.LatePenaltyApplied().process_receipt(receipt)
            actual = 'success+penalty' if len(penalty_events) > 0 else 'success'
            
    except Exception as e:
        actual = 'revert'
    
    # 记录结果
    result = {
        'case': case['name'],
        'expected': case['expected'],
        'actual': actual,
        'status': 'Pass' if actual == case['expected'] else 'Fail',
        'phase': get_current_phase(),
        'block_time': datetime.fromtimestamp(target_time).strftime('%Y-%m-%d %H:%M:%S')
    }
    results.append(result)

# 生成测试报告
df = pd.DataFrame(results)
print("\n测试结果汇总：")
print(df[['case', 'expected', 'actual', 'status', 'block_time', 'phase']])

# 可视化阶段转换
timeline = []
current_time = DEADLINE - 3600  # 开始前1小时
end_time = DEADLINE + GRACE_PERIOD + CLAIM_WINDOW + 3600

while current_time <= end_time:
    set_time(current_time)
    timeline.append({
        'timestamp': current_time,
        'phase': get_current_phase(),
        'participants': contract.functions.getParticipantCount().call()
    })
    current_time += 300  # 每5分钟记录一次

timeline_df = pd.DataFrame(timeline)
timeline_df['datetime'] = pd.to_datetime(timeline_df['timestamp'], unit='s')

plt.figure(figsize=(14, 6))
plt.plot(timeline_df['datetime'], timeline_df['participants'], label='参与者数量')
plt.fill_between(
    timeline_df['datetime'],
    0,
    timeline_df['participants'],
    where=(timeline_df['phase'] == 'ACTIVE'),
    color='green',
    alpha=0.2,
    label='活跃期'
)
plt.fill_between(
    timeline_df['datetime'],
    0,
    timeline_df['participants'],
    where=(timeline_df['phase'] == 'GRACE'),
    color='orange',
    alpha=0.2,
    label='宽限期'
)
plt.fill_between(
    timeline_df['datetime'],
    0,
    timeline_df['participants'],
    where=(timeline_df['phase'] == 'CLOSED'),
    color='red',
    alpha=0.2,
    label='关闭期'
)
plt.title("合约生命周期可视化")
plt.xlabel("时间")
plt.ylabel("参与者数量")
plt.legend()
plt.grid(True)
plt.show()

# 生成资金流动报告
def get_financial_report():
    report = {
        '初始资金': Web3.from_wei(INITIAL_ETH, 'ether'),
        '当前资金池': Web3.from_wei(contract.functions.currentPoolBalance().call(), 'ether'),
        '总锁定资金': Web3.from_wei(contract.functions.totalLocked().call(), 'ether'),
        '待领取奖励': sum(
            Web3.from_wei(contract.functions.pendingRewards(acc).call(), 'ether')
            for acc in w3.eth.accounts[1:6]
        )
    }
    return pd.DataFrame([report]).T.rename(columns={0: 'ETH'})

print("\n资金报告：")
display(get_financial_report())