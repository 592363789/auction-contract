// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// 导入Chainlink的KeeperCompatible合约库
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol"; // 引入AccessControl模块
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// 拍卖工厂合约，用于创建和跟踪所有拍卖
contract AuctionFactory is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    // 数组，用于存储所有拍卖合约的地址
    address[] public auctions;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    function initialize(address initialAdmin) public initializer {
        __AccessControl_init();
        grantRole(ADMIN_ROLE, initialAdmin);
        grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _setRoleAdmin(ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
    }

    // 创建一个新的拍卖合约
    function createAuction(
        uint _startingPrice, // 拍卖的起始价格
        uint _endPrice,
        uint _duration,     // 拍卖的持续时间
        uint _priceDecrement,
        uint _decrementInterval,
        address _depositToken,
        uint _depositAmount
    ) public {
        DutchAuction newAuction = new DutchAuction();
        newAuction.initialize(msg.sender, _startingPrice, _endPrice, _duration, _priceDecrement, _decrementInterval, _depositToken, _depositAmount);
        auctions.push(address(newAuction)); // 将新拍卖的地址添加到数组中
    }

    /*
            address _seller,
        uint _startingPrice,
        uint _endPrice,
        uint _duration,
        uint _priceDecrement,
        uint _decrementInterval,
        address _depositToken,
        uint _depositAmount
    */

    // 返回所有拍卖的地址
    function getAuctions() public view returns (address[] memory) {
        return auctions;
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    function addAdmin(address newAdmin) public onlyRole(ADMIN_ROLE) {
        grantRole(ADMIN_ROLE, newAdmin);
    }

    function removeAdmin(address admin) public onlyRole(ADMIN_ROLE) {
        revokeRole(ADMIN_ROLE, admin);
    }
}

// 拍卖合约
contract DutchAuction is KeeperCompatibleInterface, Initializable, UUPSUpgradeable, AccessControlUpgradeable {

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public seller;           // 卖家的地址
    uint public currentPrice;        // 当前拍卖价格
    uint public startPrice;          // 拍卖开始价格
    uint public endPrice;            // 拍卖结束价格

    uint public auctionEndTime;      // 拍卖结束的时间戳
    uint public startTime;           // 拍卖开始时间
    uint public priceDecrement;      // 每次降价的幅度
    uint public decrementInterval;   // 降价的间隔时间
    bool public ended;               // 拍卖是否已结束
    bool public started;             // 拍卖是否已开始

    IERC20 public depositToken;      // 押金的 ERC20 代币地址
    uint public depositAmount;       // 每个用户的押金金额
    mapping(address => bool) public hasDeposited; // 记录哪些用户支付了押金

    // 拍卖事件
    event AuctionStarted(uint startPrice, uint endPrice);
    event AuctionEnded(address winner, uint finalPrice);
    event DepositPaid(address participant);
    event DepositRefunded(address participant);

    // 初始化拍卖的初始状态
    function initialize(
        address _seller,
        uint _startingPrice,
        uint _endPrice,
        uint _duration,
        uint _priceDecrement,
        uint _decrementInterval,
        address _depositToken,
        uint _depositAmount
    ) public initializer {
        __AccessControl_init();
        seller = _seller;
        startPrice = _startingPrice;
        endPrice = _endPrice;
        auctionEndTime = block.timestamp + _duration; // 此时暂时设置结束时间，但在拍卖开始时会更新
        currentPrice = _startingPrice;
        priceDecrement = _priceDecrement;
        decrementInterval = _decrementInterval;
        depositToken = IERC20(_depositToken);
        depositAmount = _depositAmount;
        grantRole(ADMIN_ROLE, msg.sender);
    }

    // 支付押金
    function payDeposit() public {
        require(!hasDeposited[msg.sender], "Deposit already paid.");
        require(depositToken.transferFrom(msg.sender, address(this), depositAmount), "Deposit transfer failed.");
        hasDeposited[msg.sender] = true;
        emit DepositPaid(msg.sender);
    }

    // 启动拍卖
    function startAuction() public onlyRole(ADMIN_ROLE) {
        require(!started, "Auction already started.");
        started = true;
        startTime = block.timestamp;
        auctionEndTime = startTime + (auctionEndTime - startTime); // 更新实际结束时间
        emit AuctionStarted(startPrice, endPrice);
    }

    // 出价
    function bid() public { // nonReentrant
        require(started, "Auction has not started.");
        require(hasDeposited[msg.sender], "Deposit required to participate.");
        require(block.timestamp < auctionEndTime, "Auction already ended.");
        require(depositToken.balanceOf(msg.sender) >= currentPrice, "Insufficient token balance to bid.");

        // 从出价者的账户转移出价金额到卖家账户
        require(depositToken.transferFrom(msg.sender, seller, currentPrice), "Token transfer failed.");

        ended = true;
        emit AuctionEnded(msg.sender, currentPrice); // 触发拍卖结束事件
    }


    // 用户自行取回押金
    function claimRefund() public {
        require(ended, "Auction not yet ended.");
        require(hasDeposited[msg.sender], "No deposit found.");
        require(msg.sender != seller, "Seller cannot claim refund.");

        hasDeposited[msg.sender] = false;
        require(depositToken.transfer(msg.sender, depositAmount), "Refund transfer failed.");
        emit DepositRefunded(msg.sender);
    }

    // Keeper兼容的检查函数，确定是否需要执行维护
    function checkUpkeep(
        bytes calldata /* checkData */
    ) external view override returns (bool upkeepNeeded, bytes memory /* performData */) {
        upkeepNeeded = started && (block.timestamp < auctionEndTime && currentPrice > endPrice);
    }

    // Keeper执行的维护函数，更新当前价格
    function performUpkeep(
        bytes calldata /* performData */
    ) external override {
        if (started && block.timestamp < auctionEndTime && currentPrice > endPrice) {
            uint timeElapsed = block.timestamp - startTime;
            if (timeElapsed % decrementInterval == 0) {
                currentPrice = currentPrice > priceDecrement ? currentPrice - priceDecrement : endPrice;
            }
        } else if (block.timestamp >= auctionEndTime && !ended) {
            ended = true;
            emit AuctionEnded(address(0), 0); // 没有出价人时拍卖结束
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}