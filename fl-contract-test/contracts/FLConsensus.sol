// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IFLIncentive {
    function participantList() external view returns (address[] memory);
    function participants(address) external view returns (
        uint8 dataCat,
        uint8 resourceCat,
        uint96 stakePaid,
        uint40 joinTime,
        bool isRewarded,
        bool joined
    );
    function currentPhase() external view returns (uint8);
    function getPendingReward(address user) external view returns (uint256); // 新增接口方法
    function rewardsFinalized() external view returns (bool); // 新增接口方法
    function autoClosed() external view returns (bool); // 新增接口方法
}

contract FLConsensus {
    // 核心状态变量
    address public incentiveContract;
    uint256 public flRound;
    bool public isFLActive;

    // FL运行参数
    uint256 public minParticipants;
    uint256 public modelUpdateTimeout;
    uint256 public currentRoundDeadline;

    // 参与者状态跟踪
    struct FLParticipant {
        bool submittedUpdate;
        uint256 submissionTime;
        bytes32 modelHash;
    }
    mapping(uint256 => mapping(address => FLParticipant)) public flParticipants;
    address[] private cachedParticipants;

    // 事件系统
    event FLStarted(uint256 indexed round, address[] participants);
    event ModelSubmitted(address indexed participant, uint256 round, bytes32 modelHash);
    event FLCompleted(uint256 indexed round, bytes32 aggregatedModel, uint256 totalParticipants, uint256 totalSubmissions);
    event IncentiveContractUpdated(address oldContract, address newContract);

    constructor(
        address _incentiveContract,
        uint256 _minParticipants,
        uint256 _modelTimeout
    ) {
        require(_incentiveContract != address(0), "Invalid incentive contract address");
        incentiveContract = _incentiveContract;
        minParticipants = _minParticipants;
        modelUpdateTimeout = _modelTimeout;
    }

    // 核心功能函数
    modifier onlyValidParticipants() {
        require(
            IFLIncentive(incentiveContract).rewardsFinalized() && 
            !IFLIncentive(incentiveContract).autoClosed(),
            "Rewards not finalized or contract auto-closed"
        );
        _;
    }

    function updateIncentiveContract(address _newIncentiveContract) external {
        require(_newIncentiveContract != address(0), "Invalid address");
        address oldContract = incentiveContract;
        incentiveContract = _newIncentiveContract;
        emit IncentiveContractUpdated(oldContract, _newIncentiveContract);
    }

    function startFLRound() external onlyValidParticipants {
        refreshEligibleParticipants();
        require(cachedParticipants.length >= minParticipants, "Insufficient participants");

        flRound++;
        isFLActive = true;
        currentRoundDeadline = block.timestamp + modelUpdateTimeout;

        _initializeParticipants(cachedParticipants);
        emit FLStarted(flRound, cachedParticipants);
    }

    function getEligibleParticipants() public view returns (address[] memory) {
        address[] memory all = IFLIncentive(incentiveContract).participantList();
        address[] memory eligible = new address[](all.length);
        uint256 count;

        for (uint256 i = 0; i < all.length; i++) {
            address user = all[i];
            (, , , , , bool joined) = IFLIncentive(incentiveContract).participants(user);
            uint256 pending = IFLIncentive(incentiveContract).getPendingReward(user);
            
            if (joined && pending > 0) { // 正确条件
                eligible[count++] = user;
            }
        }

        // 裁剪数组
        assembly { mstore(eligible, count) }
        return eligible;
    }

    function refreshEligibleParticipants() public {
        cachedParticipants = getEligibleParticipants();
    }

    function getCachedParticipants() public view returns (address[] memory) {
        return cachedParticipants;
    }

    function submitModelUpdate(bytes32 _modelHash) external {
        require(isFLActive, "FL not active");
        require(block.timestamp < currentRoundDeadline, "Round expired");
        require(_isEligible(msg.sender), "Not eligible participant");
        require(
            !flParticipants[flRound][msg.sender].submittedUpdate,
            "Model already submitted"
        );

        flParticipants[flRound][msg.sender] = FLParticipant({
            submittedUpdate: true,
            submissionTime: block.timestamp,
            modelHash: _modelHash
        });

        emit ModelSubmitted(msg.sender, flRound, _modelHash);
    }

    function _isEligible(address _user) internal view returns (bool) {
        (, , , , , bool joined) = IFLIncentive(incentiveContract).participants(_user);
        uint256 pending = IFLIncentive(incentiveContract).getPendingReward(_user);
        return joined && pending > 0 && !flParticipants[flRound][_user].submittedUpdate;
    }

    function completeFLRound(bytes32 _aggregatedHash) external {
        require(isFLActive, "FL ongoing");
        require(block.timestamp > currentRoundDeadline, "Round ongoing");

        uint256 totalSubmissions;
        for (uint256 i = 0; i < cachedParticipants.length; i++) {
            address participant = cachedParticipants[i];
            if (!flParticipants[flRound][participant].submittedUpdate) {
                _applyPenalty(participant);
            } else {
                totalSubmissions++;
            }
        }

        isFLActive = false;
        emit FLCompleted(flRound, _aggregatedHash, cachedParticipants.length, totalSubmissions);
    }

    function _applyPenalty(address participant) internal {
        // 示例惩罚逻辑，例如记录未提交的参与者
    }

    function _initializeParticipants(address[] memory participants) internal {
        // 初始化参与者状态
    }

    function getParticipantStatus(address participant, uint256 round)
        external
        view
        returns (bool submitted, uint256 submissionTime, bytes32 modelHash)
    {
        FLParticipant memory p = flParticipants[round][participant];
        return (p.submittedUpdate, p.submissionTime, p.modelHash);
    }

    function timeRemaining() external view returns (uint256) {
        if (block.timestamp > currentRoundDeadline) {
            return 0;
        }
        return currentRoundDeadline - block.timestamp;
    }

    // 添加调试函数
    function getIncentivePhase() external view returns (uint8) {
        return IFLIncentive(incentiveContract).currentPhase();
    }

    function getIncentiveAddress() external view returns (address) {
        return incentiveContract;
    }
}