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