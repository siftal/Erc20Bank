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
    uint256 public etherPrice;
    uint256 public erc20Price;
    uint256 public collateralRatio;
    uint256 public liquidationDuration;
    address public oraclesAddr;
    address public liquidatorAddr;

    EtherDollar internal token;
    ERC20 internal collatralToken;

    Liquidator internal liquidator;

    uint256 constant internal PRECISION_POINT = 10 ** 3;
    uint256 constant internal MAX_LOAN = 10000 * 100;
    uint256 constant internal COLLATERAL_MULTIPLIER = 2;

    uint256 constant internal ETHER_TO_WEI = 10 ** 18;
    uint256 constant internal ERC20_TO_BASE_UNIT = 10 ** 18;

    address constant internal ERC20_COLLATERAL_ADDRESS = 0x0;

    enum Types {
        ETHER_PRICE,
        ERC20_COLLATERAL_PRICE,
        COLLATERAL_RATIO,
        LIQUIDATION_DURATION
    }

    enum CollateralTypes {
        ETHER,
        ERC20
    }

    enum LoanStates {
        ACTIVE,
        UNDER_LIQUIDATION,
        LIQUIDATED,
        SETTLED
    }

    struct Loan {
        address recipient;
        CollateralTypes collateralType;
        uint256 collateralAmount;
        uint256 amount;
        LoanStates state;
    }

    mapping(uint256 => Loan) public loans;

    event LoanGot(address indexed recipient, uint256 indexed loanId, uint256 amount, CollateralTypes collateralType, uint256 collateralAmount);
    event LoanSettled(address recipient, uint256 indexed loanId, uint256 collateralAmount, CollateralTypes collateralType, uint256 amount);
    event CollateralIncreased(address indexed recipient, uint256 indexed loanId, CollateralTypes collateralType, uint256 collateralAmount);
    event CollateralDecreased(address indexed recipient, uint256 indexed loanId, CollateralTypes collateralType, uint256 collateralAmount);

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

    constructor(address tokenAddr)
        public
    {
        token = EtherDollar(tokenAddr);
        collatralToken = ERC20(ERC20_COLLATERAL_ADDRESS);
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
            uint256 amount = msg.value.mul(PRECISION_POINT).mul(etherPrice).div(collateralRatio).div(ETHER_TO_WEI).div(COLLATERAL_MULTIPLIER);
            getLoan(amount, uint8(CollateralTypes.ETHER));
        }
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
        if (uint8(Types.ETHER_PRICE) == _type) {
            etherPrice = value;
        } else if (uint8(Types.ERC20_COLLATERAL_PRICE) == _type) {
            erc20Price = value;
        } else if (uint8(Types.COLLATERAL_RATIO) == _type) {
            collateralRatio = value;
        } else if (uint8(Types.LIQUIDATION_DURATION) == _type) {
            liquidationDuration = value;
        }
    }

    /**
     * @notice Deposit ether to borrow ether dollar.
     * @param amount The amount of requsted loan in ether dollar.
     * @param collateralType The type of the collateral.
     */
    function getLoan(uint256 amount, uint8 collateralType)
        public
        payable
        throwIfEqualToZero(amount)
    {
        uint256 collateralAmount;
        require (amount <= MAX_LOAN, EXCEEDED_MAX_LOAN);
        if (uint8(CollateralTypes.ETHER) == collateralType) {
            collateralAmount = msg.value;
        } else if (uint8(CollateralTypes.ERC20) == collateralType) {
            collateralAmount = collatralToken.allowance(msg.sender, address(this));
            require (collatralToken.transferFrom(msg.sender, address(this), collateralAmount));
        }

        require (minCollateral(amount, collateralType) <= collateralAmount, INSUFFICIENT_COLLATERAL);

        uint256 loanId = ++lastLoanId;
        loans[loanId].recipient = msg.sender;
        loans[loanId].collateralType = CollateralTypes(collateralType);
        loans[loanId].collateralAmount = collateralAmount;
        loans[loanId].amount = amount;
        loans[loanId].state = LoanStates.ACTIVE;
        emit LoanGot(msg.sender, loanId, amount, CollateralTypes(collateralType), collateralAmount);
        token.mint(msg.sender, amount);
    }

    /**
     * @notice Increase the loan's collateral.
     * @param loanId The loan id.
     */
    function increaseCollateral(uint256 loanId)
        external
        payable
        checkLoanStates(loanId, LoanStates.ACTIVE)
    {
        uint256 collateralAmount;
        if (loans[loanId].collateralType == CollateralTypes.ETHER) {
            collateralAmount = msg.value;
        } else if (loans[loanId].collateralType == CollateralTypes.ERC20) {
            collateralAmount = collatralToken.allowance(msg.sender, address(this));
            require (collatralToken.transferFrom(msg.sender, address(this), collateralAmount));
        }

        require(0 < collateralAmount, INVALID_AMOUNT);

        loans[loanId].collateralAmount = loans[loanId].collateralAmount.add(collateralAmount);
        emit CollateralIncreased(msg.sender, loanId, loans[loanId].collateralType, collateralAmount);
    }

    /**
     * @notice Pay back extera collateral.
     * @param loanId The loan id.
     * @param amount The amout of extera collateral.
     */
    function decreaseCollateral(uint256 loanId, uint256 amount)
        external
        throwIfEqualToZero(amount)
        onlyLoanOwner(loanId)
    {
        require(loans[loanId].state != LoanStates.UNDER_LIQUIDATION, INVALID_LOAN_STATE);

        require(minCollateral(loans[loanId].amount, uint8(loans[loanId].collateralType)) <= loans[loanId].collateralAmount.sub(amount), INSUFFICIENT_COLLATERAL);

        loans[loanId].collateralAmount = loans[loanId].collateralAmount.sub(amount);
        emit CollateralDecreased(msg.sender, loanId, loans[loanId].collateralType, amount);
        if (loans[loanId].collateralType == CollateralTypes.ETHER) {
            loans[loanId].recipient.transfer(amount);
        } else if (loans[loanId].collateralType == CollateralTypes.ERC20) {
            collatralToken.transfer(loans[loanId].recipient, amount);
        }
    }

    /**
     * @notice pay ether dollars back to settle the loan.
     * @param loanId The loan id.
     * @param amount The ether dollar amount payed back.
     */
    function settleLoan(uint256 loanId, uint256 amount)
        external
        checkLoanStates(loanId, LoanStates.ACTIVE)
        throwIfEqualToZero(amount)
    {
        require(amount <= loans[loanId].amount, INVALID_AMOUNT);

        require(token.transferFrom(msg.sender, address(this), amount), INSUFFICIENT_ALLOWANCE);

        uint256 payback = loans[loanId].collateralAmount.mul(amount).div(loans[loanId].amount);
        token.burn(amount);
        loans[loanId].collateralAmount = loans[loanId].collateralAmount.sub(payback);
        loans[loanId].amount = loans[loanId].amount.sub(amount);
        if (loans[loanId].amount == 0) {
            loans[loanId].state = LoanStates.SETTLED;
        }

        emit LoanSettled(loans[loanId].recipient, loanId, payback, loans[loanId].collateralType, amount);
        if (loans[loanId].collateralType == CollateralTypes.ETHER) {
            loans[loanId].recipient.transfer(payback);
        } else if (loans[loanId].collateralType == CollateralTypes.ERC20) {
            collatralToken.transfer(loans[loanId].recipient, payback);
        }
    }

    /**
     * @notice Start liquidation process of the loan.
     * @param loanId The loan id.
     */
    function liquidate(uint256 loanId)
        external
        checkLoanStates(loanId, LoanStates.ACTIVE)
    {
        require (loans[loanId].collateralAmount < minCollateral(loans[loanId].amount, uint8(loans[loanId].collateralType)), SUFFICIENT_COLLATERAL);

        loans[loanId].state = LoanStates.UNDER_LIQUIDATION;
        liquidator.startLiquidation(
            loanId,
            uint8(loans[loanId].collateralType),
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
        checkLoanStates(loanId, LoanStates.UNDER_LIQUIDATION)
    {
        require (collateral <= loans[loanId].collateralAmount, INVALID_AMOUNT);

        loans[loanId].collateralAmount = loans[loanId].collateralAmount.sub(collateral);
        loans[loanId].amount = 0;
        loans[loanId].state = LoanStates.LIQUIDATED;
        if (loans[loanId].collateralType == CollateralTypes.ETHER) {
            buyer.transfer(collateral);
        } else if (loans[loanId].collateralType == CollateralTypes.ERC20) {
            collatralToken.transfer(buyer, collateral);
        }
    }

    /**
     * @notice Minimum collateral in wei that is required for borrowing `amount`.
     * @param collateralType The type of the collateral.
     * @param amount The amount of the loan.
     */
    function minCollateral(uint256 amount, uint8 collateralType)
        public
        view
        returns (uint256)
    {
        uint256 price;
        uint256 toBaseUnit;
        if (uint8(CollateralTypes.ETHER) == collateralType) {
            price = etherPrice;
            toBaseUnit = ETHER_TO_WEI;
        } else if (uint8(CollateralTypes.ERC20) == collateralType) {
            price = erc20Price;
            toBaseUnit = ERC20_TO_BASE_UNIT;
        }
        uint256 min = amount.mul(collateralRatio).mul(toBaseUnit).div(PRECISION_POINT).div(price);
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
    modifier checkLoanStates(uint256 loanId, LoanStates needState) {
        require(loans[loanId].state == needState, INVALID_LOAN_STATE);
        _;
    }
}
