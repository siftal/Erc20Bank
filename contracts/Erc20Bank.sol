pragma solidity ^0.4.24;

import "./openzeppelin/contracts/math/SafeMath.sol";
import "./openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./EtherDollar.sol";
import "./Liquidator.sol";


/**
 * @title Erc20Bank contract.
 */
contract Erc20Bank {
    using SafeMath for uint256;

    uint256 public lastLoanId;
    uint256 public collateralRatio;
    uint256 public liquidationDuration;
    address public oraclesAddr;
    address public liquidatorAddr;

    EtherDollar internal token;
    Liquidator internal liquidator;

    uint256 constant internal PRECISION_POINT = 10 ** 3;
    uint256 constant internal MAX_LOAN = 10000 * 100;
    uint256 constant internal COLLATERAL_MULTIPLIER = 2;

    enum Types {
        COLLATERAL_RATIO,
        LIQUIDATION_DURATION
    }

    enum LoanState {
        ACTIVE,
        UNDER_LIQUIDATION,
        LIQUIDATED,
        SETTLED
    }

    struct Collateral {
        bool isActive;
        uint256 price;
        uint32 decimals;
        string symbol;
        ERC20 instance;
    }

    struct Loan {
        address recipient;
        address collateralAddr;
        uint256 collateralAmount;
        uint256 amount;
        LoanState state;
    }

    mapping(address => Collateral) public collaterals;

    mapping(uint256 => Loan) public loans;

    event LoanGot(address indexed recipient, uint256 indexed loanId, uint256 amount, address collateralAddr, uint256 collateralAmount);
    event LoanSettled(address recipient, uint256 indexed loanId, uint256 collateralAmount, address collateralAddr, uint256 amount);
    event CollateralIncreased(address indexed recipient, uint256 indexed loanId, address collateralAddr, uint256 collateralAmount);
    event CollateralDecreased(address indexed recipient, uint256 indexed loanId, address collateralAddr, uint256 collateralAmount);
    event CollateralAdded(address collateralAddr, uint256 price, uint32 decimals, string symbol);
    event CollateralRemoved(address collateralAddr);
    event CollateralPriceSet(address collateralAddr, uint256 newPrice);

    string private constant INVALID_AMOUNT = "INVALID_AMOUNT";
    string private constant INITIALIZED_BEFORE = "INITIALIZED_BEFORE";
    string private constant SUFFICIENT_COLLATERAL = "SUFFICIENT_COLLATERAL";
    string private constant INSUFFICIENT_COLLATERAL = "INSUFFICIENT_COLLATERAL";
    string private constant INSUFFICIENT_ALLOWANCE = "INSUFFICIENT_ALLOWANCE";
    string private constant ONLY_LOAN_OWNER = "ONLY_LOAN_OWNER";
    string private constant ONLY_LIQUIDATOR = "ONLY_LIQUIDATOR";
    string private constant ONLY_ORACLES = "ONLY_ORACLE";
    string private constant INVALID_LOAN_STATE = "INVALID_LOAN_STATE";
    string private constant EXCEEDED_MAX_LOAN = "EXCEEDED_MAX_LOAN";
    string private constant ALREADY_EXIST = "ALREADY_EXIST";
    string private constant DOES_NOT_EXIST = "DOES_NOT_EXIST";

    constructor(address _tokenAddr)
        public
    {
        token = EtherDollar(_tokenAddr);
        collateralRatio = 1500; // = 1.5 * PRECISION_POINT
        liquidationDuration = 7200; // = 2 hours
    }

    /**
     * @notice Gives out as much as half the maximum loan you can possibly receive from the smart contract
     * @dev Fallback function.
     */
    function() external
      payable
    {
        if (msg.value > 0) {
            uint256 amount = msg.value.mul(PRECISION_POINT).mul(collaterals[address(0)].price).div(collateralRatio).div(collaterals[address(0)].decimals).div(COLLATERAL_MULTIPLIER);
            getLoan(amount, address(0));
        }
    }

    /**
     * @notice Add an ERC20 collateral.
     * @param collateralAddr The collateral contract address.
     * @param price The collateral price.
     * @param decimals The collateral decimals address.
     * @param symbol The collateral symbol.
     */
    function addCollateral(address collateralAddr, uint256 price, uint32 decimals, string symbol)
        external
        onlyOracles
    {
        require (!collaterals[collateralAddr].isActive, ALREADY_EXIST);

        collaterals[collateralAddr].isActive = true;
        collaterals[collateralAddr].price = price;
        collaterals[collateralAddr].decimals = decimals;
        collaterals[collateralAddr].symbol = symbol;
        collaterals[collateralAddr].instance = ERC20(collateralAddr);
        emit CollateralAdded(collateralAddr, price, decimals, symbol);
    }

    /**
     * @notice Remove the ERC20 collateral.
     * @param collateralAddr The collateral contract address.
     */
    function removeCollateral(address collateralAddr)
        external
        onlyOracles
    {
        require (collaterals[collateralAddr].isActive, DOES_NOT_EXIST);

        collaterals[collateralAddr].isActive = false;
        emit CollateralRemoved(collateralAddr);
    }

    /**
     * @notice Add the ERC20 collateral price.
     * @param collateralAddr The collateral contract address.
     * @param newPrice The collateral price.
     */
    function setCollateralPrice(address collateralAddr, uint256 newPrice)
        external
        onlyOracles
    {
        require (collaterals[collateralAddr].isActive, DOES_NOT_EXIST);

        collaterals[collateralAddr].price = newPrice;
        emit CollateralPriceSet(collateralAddr, newPrice);
    }

    /**
     * @notice Set Liquidator's address.
     * @param _liquidatorAddr The Liquidator's contract address.
     */
    function setLiquidator(address _liquidatorAddr)
        external
    {
        require(liquidatorAddr == address(0), INITIALIZED_BEFORE);

        liquidatorAddr = _liquidatorAddr;
        liquidator = Liquidator(_liquidatorAddr);
    }

    /**
     * @notice Set oracle's address.
     * @param _oraclesAddr The oracle's contract address.
     */
    function setOracle(address _oraclesAddr)
        external
    {
        require (oraclesAddr == address(0), INITIALIZED_BEFORE);

        oraclesAddr = _oraclesAddr;
    }

    /**
     * @notice Set important varibales by oracles.
     * @param _type Type of the variable.
     * @param value Amount of the variable.
     */
    function setVariable(uint8 _type, uint256 value)
        external
        onlyOracles
        throwIfEqualToZero(value)
    {
        if (uint8(Types.COLLATERAL_RATIO) == _type) {
            collateralRatio = value;
        } else if (uint8(Types.LIQUIDATION_DURATION) == _type) {
            liquidationDuration = value;
        }
    }

    /**
     * @notice Deposit ether to borrow ether dollar.
     * @param amount The amount of requsted loan in ether dollar.
     * @param collateralAddr The collateral contract address.
     */
    function getLoan(uint256 amount, address collateralAddr)
        public
        payable
        throwIfEqualToZero(amount)
    {
        uint256 collateralAmount;
        require (amount <= MAX_LOAN, EXCEEDED_MAX_LOAN);

        if (collateralAddr == address(0)) {
            collateralAmount = msg.value;
        } else {
            ERC20 colatralToken = collaterals[collateralAddr].instance;
            collateralAmount = colatralToken.allowance(msg.sender, address(this));
            require (colatralToken.transferFrom(msg.sender, address(this), collateralAmount));
        }

        require (minCollateral(collateralAddr, amount) <= collateralAmount, INSUFFICIENT_COLLATERAL);

        uint256 loanId = ++lastLoanId;
        loans[loanId].recipient = msg.sender;
        loans[loanId].collateralAddr = collateralAddr;
        loans[loanId].collateralAmount = collateralAmount;
        loans[loanId].amount = amount;
        loans[loanId].state = LoanState.ACTIVE;
        emit LoanGot(msg.sender, loanId, amount, collateralAddr, collateralAmount);
        token.mint(msg.sender, amount);
    }

    /**
     * @notice Increase the loan's collateral.
     * @param loanId The loan id.
     */
    function increaseCollateral(uint256 loanId)
        external
        payable
        checkLoanState(loanId, LoanState.ACTIVE)
    {
        uint256 collateralAmount;
        if (loans[loanId].collateralAddr == address(0)) {
            collateralAmount = msg.value;
        } else {
            ERC20 colatralToken = collaterals[loans[loanId].collateralAddr].instance;
            collateralAmount = colatralToken.allowance(msg.sender, address(this));
            require (colatralToken.transferFrom(msg.sender, address(this), collateralAmount));
        }

        require(0 < collateralAmount, INVALID_AMOUNT);

        loans[loanId].collateralAmount = loans[loanId].collateralAmount.add(collateralAmount);
        emit CollateralIncreased(msg.sender, loanId, address(colatralToken), collateralAmount);
    }

    /**
     * @notice Pay back extera collateral.
     * @param loanId The loan id.
     * @param amount The amout of extera colatral.
     */
    function decreaseCollateral(uint256 loanId, uint256 amount)
        external
        throwIfEqualToZero(amount)
        onlyLoanOwner(loanId)
    {
        require(loans[loanId].state != LoanState.UNDER_LIQUIDATION, INVALID_LOAN_STATE);

        address collateralAddr = loans[loanId].collateralAddr;
        require(minCollateral(collateralAddr, loans[loanId].amount) <= loans[loanId].collateralAmount.sub(amount), INSUFFICIENT_COLLATERAL);

        loans[loanId].collateralAmount = loans[loanId].collateralAmount.sub(amount);
        emit CollateralDecreased(msg.sender, loanId, collateralAddr, amount);
        if (collateralAddr == address(0)) {
            loans[loanId].recipient.transfer(amount);
        } else {
            ERC20 colatralToken = collaterals[collateralAddr].instance;
            colatralToken.transfer(loans[loanId].recipient, amount);
        }
    }

    /**
     * @notice pay ether dollars back to settle the loan.
     * @param loanId The loan id.
     * @param amount The ether dollar amount payed back.
     */
    function settleLoan(uint256 loanId, uint256 amount)
        external
        checkLoanState(loanId, LoanState.ACTIVE)
        throwIfEqualToZero(amount)
    {
        require(amount <= loans[loanId].amount, INVALID_AMOUNT);

        require(token.transferFrom(msg.sender, address(this), amount), INSUFFICIENT_ALLOWANCE);

        uint256 payback = loans[loanId].collateralAmount.mul(amount).div(loans[loanId].amount);
        token.burn(amount);
        loans[loanId].collateralAmount = loans[loanId].collateralAmount.sub(payback);
        loans[loanId].amount = loans[loanId].amount.sub(amount);
        if (loans[loanId].amount == 0) {
            loans[loanId].state = LoanState.SETTLED;
        }

        emit LoanSettled(loans[loanId].recipient, loanId, payback, loans[loanId].collateralAddr, amount);
        if (loans[loanId].collateralAddr == address(0)) {
            loans[loanId].recipient.transfer(payback);
        } else {
            ERC20 colatralToken = collaterals[loans[loanId].collateralAddr].instance;
            colatralToken.transfer(loans[loanId].recipient, payback);
        }
    }

    /**
     * @notice Start liquidation process of the loan.
     * @param loanId The loan id.
     */
    function liquidate(uint256 loanId)
        external
        checkLoanState(loanId, LoanState.ACTIVE)
    {
        require (loans[loanId].collateralAmount < minCollateral(loans[loanId].collateralAddr, loans[loanId].amount), SUFFICIENT_COLLATERAL);

        loans[loanId].state = LoanState.UNDER_LIQUIDATION;
        liquidator.startLiquidation(
            loanId,
            loans[loanId].collateralAddr,
            loans[loanId].collateralAmount,
            loans[loanId].amount,
            liquidationDuration
        );
    }

    /**
     * @dev pay a part of the collateral to the auction's winner.
     * @param loanId The loan id.
     * @param collateral The bid of winner.
     * @param buyer The winner account.
     */
    function liquidated(uint256 loanId, uint256 collateral, address buyer)
        external
        onlyLiquidator
        checkLoanState(loanId, LoanState.UNDER_LIQUIDATION)
    {
        require (collateral <= loans[loanId].collateralAmount, INVALID_AMOUNT);

        loans[loanId].collateralAmount = loans[loanId].collateralAmount.sub(collateral);
        loans[loanId].amount = 0;
        loans[loanId].state = LoanState.LIQUIDATED;
        if (loans[loanId].collateralAddr == address(0)) {
            buyer.transfer(collateral);
        } else {
            ERC20 colatralToken = collaterals[loans[loanId].collateralAddr].instance;
            colatralToken.transfer(loans[loanId].recipient, collateral);
        }
    }


    /**
     * @notice Minimum collateral in wei that is required for borrowing `amount`.
     * @param collateralAddr The collateral contract address.
     * @param amount The amount of the loan.
     */
    function minCollateral(address collateralAddr, uint256 amount)
        public
        view
        returns (uint256)
    {
        uint256 min = amount.mul(collateralRatio).mul(collaterals[collateralAddr].decimals).div(PRECISION_POINT).div(collaterals[collateralAddr].price);
        return min;
    }

    /**
     * @dev Throws if called by any account other than our Oracle.
     */
    modifier onlyOracles() {
        require(msg.sender == oraclesAddr, ONLY_ORACLES);
        _;
    }

    /**
     * @dev Throws if called by any account other than our Liquidator.
     */
    modifier onlyLiquidator() {
        require(msg.sender == liquidatorAddr, ONLY_LIQUIDATOR);
        _;
    }

    /**
     * @dev Throws if the number is equal to zero.
     * @param number The number to validate.
     */
    modifier throwIfEqualToZero(uint number) {
        require(number != 0, INVALID_AMOUNT);
        _;
    }

    /**
     * @dev Throws if called by any account other than the owner of the loan.
     * @param loanId The loan id.
     */
    modifier onlyLoanOwner(uint256 loanId) {
        require(loans[loanId].recipient == msg.sender, ONLY_LOAN_OWNER);
        _;
    }

    /**
     * @dev Throws if state is not equal to needState.
     * @param loanId The id of the loan.
     * @param needState The state which needed.
     */
    modifier checkLoanState(uint256 loanId, LoanState needState) {
        require(loans[loanId].state == needState, INVALID_LOAN_STATE);
        _;
    }
}