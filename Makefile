-include .env
export

build  :; forge build
size   :; forge build --sizes
clean  :; forge clean
fmt    :; forge fmt

# All tests run against a Robinhood Chain fork (see .env)
test   :; forge test -vv
trace  :; forge test -vvv
gas    :; forge test --gas-report
test-contract :; forge test -vv --match-contract $(contract)
test-test     :; forge test -vv --match-test $(test)
trace-test    :; forge test -vvvv --match-test $(test)
snapshot :; forge snapshot -vv
coverage :; forge coverage --ir-minimum

coverage-html:
	forge coverage --report lcov --ir-minimum
	lcov --remove lcov.info 'test/**' 'script/**' --output-file lcov.info
	genhtml -o coverage-report lcov.info
