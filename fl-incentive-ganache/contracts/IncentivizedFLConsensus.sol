// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract FixedFLConsensus {
    // =====================
    // 数据结构
    // =====================
    struct Participant {
        uint256 stake;
        uint256 reputation;
        uint256 lastActiveRound;
        bool isMalicious;
    }

    struct TrainingRound {
        uint256 roundId;
        bytes32 aggregatedModel;
        uint256 totalReward;
        uint256 submissionEnd;
        uint256 validationEnd;
        mapping(address => bytes32) submissions;
        mapping(address => bool) validations;
    }

    // =====================
    // 状态变量
    // =====================
    address public immutable governance;
    uint256 public currentRound;
    uint256 public baseStake = 0.1 ether;
    uint256 public rewardRate = 10;
    uint256 public participantCount;
    
    mapping(uint256 => TrainingRound) public rounds;
    mapping(address => Participant) public participants;
    address[] public allParticipants;
    address[] public committee;

    // =====================
    // 事件系统
    // =====================
    event NewRound(uint256 indexed roundId, uint256 rewardPool);
    event Staked(address indexed participant, uint256 amount);
    event ModelSubmitted(address participant, bytes32 modelHash);
    event ModelValidated(address validator, address submitter, bool isValid);
    event RewardPaid(address participant, uint256 amount);

    // =====================
    // 核心功能实现（已修复）
    // =====================
    constructor() {
        governance = msg.sender;
        _initNewRound();
    }

    function stakeAndRegister() external payable {
        require(msg.value >= baseStake, "Insufficient stake");
        require(participants[msg.sender].stake == 0, "Already registered");
        
        participants[msg.sender] = Participant({
            stake: msg.value,
            reputation: 50,
            lastActiveRound: currentRound,
            isMalicious: false
        });
        
        allParticipants.push(msg.sender);
        participantCount++;
        emit Staked(msg.sender, msg.value);
    }

    function submitModel(bytes32 modelHash) external {
        Participant storage p = participants[msg.sender];
        require(p.stake >= baseStake, "Not staked");
        require(!p.isMalicious, "Blacklisted");
        require(block.timestamp < rounds[currentRound].submissionEnd, "Submission closed");
        
        TrainingRound storage round = rounds[currentRound];
        require(round.submissions[msg.sender] == bytes32(0), "Already submitted");
        
        round.submissions[msg.sender] = modelHash;
        p.lastActiveRound = currentRound;
        emit ModelSubmitted(msg.sender, modelHash);
    }

    function validateModel(address submitter, bool isValid) external {
        require(_isCommitteeMember(msg.sender), "Committee only");
        require(block.timestamp < rounds[currentRound].validationEnd, "Validation closed");
        
        TrainingRound storage round = rounds[currentRound];
        round.validations[submitter] = isValid;

        if (!isValid) {
            participants[submitter].isMalicious = true;
            _slashStake(submitter, baseStake / 2);
        }
        
        _updateReputation(submitter, isValid ? 5 : -20);
        _updateReputation(msg.sender, isValid ? 2 : -10);
        emit ModelValidated(msg.sender, submitter, isValid);
    }

    function finalizeRound(bytes32 aggregatedHash) external onlyGovernance {
        require(block.timestamp >= rounds[currentRound].validationEnd, "Validation ongoing");
        require(_checkConsensus(), "Consensus failed");
        
        _distributeRewards();
        _initNewRound();
        rounds[currentRound].aggregatedModel = aggregatedHash;
    }

    // =====================
    // 修复后的关键函数
    // =====================
    function _selectCommittee() private {
        delete committee;
        address[] memory candidates = _getValidCandidates();
        require(candidates.length >= 5, "Not enough candidates");

        bytes32 randSeed = keccak256(abi.encodePacked(blockhash(block.number - 1)));
        uint256 remaining = candidates.length;

        for (uint i = 0; i < 5; i++) {
            uint256 idx = uint256(randSeed) % remaining;
            committee.push(candidates[idx]);
            
            // 将已选元素与当前范围末尾元素交换
            if (idx != remaining - 1) {
                (candidates[idx], candidates[remaining - 1]) = 
                    (candidates[remaining - 1], candidates[idx]);
            }
            
            remaining--;
            randSeed = keccak256(abi.encode(randSeed));
        }
    }

    function _getValidCandidates() private view returns (address[] memory) {
        address[] memory valid = new address[](participantCount);
        uint256 count;
        
        for (uint256 i = 0; i < allParticipants.length; i++) {
            address p = allParticipants[i];
            Participant memory participant = participants[p];
            
            if (participant.stake >= baseStake &&
                !participant.isMalicious &&
                participant.lastActiveRound >= currentRound - 1) 
            {
                valid[count++] = p;
            }
        }
        
        // 调整数组长度
        assembly { mstore(valid, count) }
        return valid;
    }

    // =====================
    // 辅助函数
    // =====================
    modifier onlyGovernance() {
        require(msg.sender == governance, "Governance only");
        _;
    }

    function _initNewRound() private {
        currentRound++;
        _selectCommittee();
        
        rounds[currentRound] = TrainingRound({
            roundId: currentRound,
            aggregatedModel: bytes32(0),
            totalReward: address(this).balance,
            submissionEnd: block.timestamp + 1 hours,
            validationEnd: block.timestamp + 3 hours
        });
        emit NewRound(currentRound, address(this).balance);
    }

    function _checkConsensus() private view returns (bool) {
        address[] memory subs = _getSubmitters();
        uint256 validCount;
        
        for (uint i = 0; i < subs.length; i++) {
            if (rounds[currentRound].validations[subs[i]]) {
                validCount++;
            }
        }
        return validCount * 100 / subs.length >= 66;
    }

    function _distributeRewards() private {
        TrainingRound storage round = rounds[currentRound];
        address[] memory validators = _getValidCandidates();
        uint256 totalReputation;
        
        for (uint i = 0; i < validators.length; i++) {
            totalReputation += participants[validators[i]].reputation;
        }
        
        for (uint i = 0; i < validators.length; i++) {
            address p = validators[i];
            uint256 share = (round.totalReward * participants[p].reputation) / totalReputation;
            payable(p).transfer(share);
            emit RewardPaid(p, share);
        }
    }

    function _slashStake(address target, uint256 amount) private {
        participants[target].stake -= amount;
        payable(governance).transfer(amount);
    }

    function _updateReputation(address target, int256 delta) private {
        uint256 current = participants[target].reputation;
        participants[target].reputation = delta > 0 ?
            (current + uint256(delta) > 100 ? 100 : current + uint256(delta)) :
            (current < uint256(-delta) ? 0 : current - uint256(-delta));
    }

    function _isCommitteeMember(address addr) private view returns (bool) {
        for (uint i = 0; i < committee.length; i++) {
            if (committee[i] == addr) return true;
        }
        return false;
    }

    function _getSubmitters() private view returns (address[] memory) {
        address[] memory submitters = new address[](participantCount);
        uint256 count;
        
        for (uint i = 0; i < allParticipants.length; i++) {
            if (rounds[currentRound].submissions[allParticipants[i]] != bytes32(0)) {
                submitters[count++] = allParticipants[i];
            }
        }
        return submitters;
    }

    receive() external payable {}
}