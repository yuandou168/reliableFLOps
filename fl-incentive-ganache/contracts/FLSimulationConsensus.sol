// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract BasicFLConsensus {
    // =====================
    // 数据结构
    // =====================
    struct Participant {
        address addr;
        bool isRegistered;
        uint256 lastActiveRound;
    }

    struct ModelSubmission {
        bytes32 modelHash;
        uint256 timestamp;
        bool isValid;
    }

    struct TrainingRound {
        uint256 roundId;
        bytes32 aggregatedModel;
        uint256 submissionDeadline;
        uint256 validationDeadline;
        mapping(address => ModelSubmission) submissions;
        address[] validators;
    }

    // =====================
    // 状态变量
    // =====================
    address public immutable coordinator; // 协调节点地址
    uint256 public currentRound;
    uint256 public committeeSize = 5;     // 验证委员会人数
    uint256 public submissionPeriod = 1 hours;
    uint256 public validationPeriod = 2 hours;
    
    mapping(uint256 => TrainingRound) public rounds;
    mapping(address => Participant) public participants;
    address[] public committeeMembers;

    // =====================
    // 事件系统
    // =====================
    event NewRoundStarted(uint256 indexed roundId, uint256 deadline);
    event ModelSubmitted(address indexed participant, bytes32 modelHash);
    event ModelValidated(address validator, address participant, bool isValid);
    event AggregationCompleted(uint256 indexed roundId, bytes32 aggregatedHash);

    // =====================
    // 权限控制
    // =====================
    modifier onlyCoordinator() {
        require(msg.sender == coordinator, "Coordinator only");
        _;
    }

    modifier onlyCommittee() {
        require(_isCommitteeMember(msg.sender), "Committee only");
        _;
    }

    // =====================
    // 主构造函数
    // =====================
    constructor() {
        coordinator = msg.sender;
        _initNewRound();
    }

    // =====================
    // 核心功能
    // =====================
    
    // 注册参与者（白名单机制）
    function registerParticipant(address participant) external onlyCoordinator {
        require(!participants[participant].isRegistered, "Already registered");
        
        participants[participant] = Participant({
            addr: participant,
            isRegistered: true,
            lastActiveRound: 0
        });
    }

    // 提交模型（参与者调用）
    function submitModel(bytes32 modelHash) external {
        Participant storage p = participants[msg.sender];
        require(p.isRegistered, "Not registered");
        require(block.timestamp < rounds[currentRound].submissionDeadline, "Submission closed");
        
        TrainingRound storage round = rounds[currentRound];
        require(round.submissions[msg.sender].timestamp == 0, "Already submitted");
        
        round.submissions[msg.sender] = ModelSubmission({
            modelHash: modelHash,
            timestamp: block.timestamp,
            isValid: false
        });
        
        emit ModelSubmitted(msg.sender, modelHash);
    }

    // 验证模型（委员会成员调用）
    function validateModel(address submitter, bool isValid) external onlyCommittee {
        TrainingRound storage round = rounds[currentRound];
        require(block.timestamp < round.validationDeadline, "Validation closed");
        
        ModelSubmission storage submission = round.submissions[submitter];
        require(submission.timestamp > 0, "No submission");
        
        submission.isValid = isValid;
        emit ModelValidated(msg.sender, submitter, isValid);
    }

    // 触发聚合（协调节点调用）
    function triggerAggregation(bytes32 aggregatedHash) external onlyCoordinator {
        TrainingRound storage round = rounds[currentRound];
        require(block.timestamp >= round.validationDeadline, "Validation ongoing");
        require(_checkConsensus(), "Consensus not reached");
        
        round.aggregatedModel = aggregatedHash;
        _initNewRound();
        emit AggregationCompleted(currentRound, aggregatedHash);
    }

    // =====================
    // 内部逻辑
    // =====================
    function _initNewRound() private {
        currentRound++;
        _selectCommittee();
        
        rounds[currentRound] = TrainingRound({
            roundId: currentRound,
            aggregatedModel: bytes32(0),
            submissionDeadline: block.timestamp + submissionPeriod,
            validationDeadline: block.timestamp + submissionPeriod + validationPeriod,
            validators: new address[](0)
        });
        
        emit NewRoundStarted(currentRound, rounds[currentRound].submissionDeadline);
    }

    function _selectCommittee() private {
        delete committeeMembers;
        
        // 简单随机选择（实际应使用更安全的随机数）
        bytes32 randSeed = blockhash(block.number - 1);
        uint256 participantCount = _getActiveParticipants().length;
        
        for (uint i = 0; i < committeeSize; i++) {
            uint256 idx = uint256(randSeed) % participantCount;
            committeeMembers.push(_getActiveParticipants()[idx]);
            randSeed = keccak256(abi.encode(randSeed));
        }
    }

    function _checkConsensus() private view returns (bool) {
        uint256 validCount;
        address[] memory subs = _getSubmitters(currentRound);
        
        for (uint i = 0; i < subs.length; i++) {
            if (rounds[currentRound].submissions[subs[i]].isValid) {
                validCount++;
            }
        }
        return validCount * 100 / subs.length >= 66; // 66%阈值
    }

    // =====================
    // 视图函数
    // =====================
    function getCurrentCommittee() external view returns (address[] memory) {
        return committeeMembers;
    }

    function getRoundSubmissions(uint256 roundId) external view returns (address[] memory, bytes32[] memory) {
        address[] memory submitters = _getSubmitters(roundId);
        bytes32[] memory hashes = new bytes32[](submitters.length);
        
        for (uint i = 0; i < submitters.length; i++) {
            hashes[i] = rounds[roundId].submissions[submitters[i]].modelHash;
        }
        return (submitters, hashes);
    }

    // =====================
    // 辅助函数
    // =====================
    function _getActiveParticipants() private view returns (address[] memory) {
        address[] memory active = new address[](committeeSize * 2);
        uint256 count;
        
        for (uint i = 0; i < committeeMembers.length; i++) {
            if (participants[committeeMembers[i]].lastActiveRound >= currentRound - 1) {
                active[count++] = committeeMembers[i];
            }
        }
        return active;
    }

    function _getSubmitters(uint256 roundId) private view returns (address[] memory) {
        TrainingRound storage round = rounds[roundId];
        address[] memory submitters = new address[](committeeSize * 2);
        uint256 count;
        
        for (uint i = 0; i < committeeMembers.length; i++) {
            if (round.submissions[committeeMembers[i]].timestamp > 0) {
                submitters[count++] = committeeMembers[i];
            }
        }
        return submitters;
    }

    function _isCommitteeMember(address addr) private view returns (bool) {
        for (uint i = 0; i < committeeMembers.length; i++) {
            if (committeeMembers[i] == addr) return true;
        }
        return false;
    }
}