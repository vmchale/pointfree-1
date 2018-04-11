ci:
    cabal new-build
    cabal new-test
    yamllint stack.yaml
    yamllint .hlint.yaml
    stack build --test --no-run-tests
    weeder .
