#!/bin/bash

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

pwd && ls -ltr
cd frontend || exit 0
pwd && ls -ltr

## skip all tests when console is not installed
if ! (oc get clusteroperator console --kubeconfig=${KUBECONFIG}) ; then
  echo "console is not installed, skipping all console tests."
  exit 0
fi

## determine if it is hypershift guest cluster or not
if ! (oc get node --kubeconfig=${KUBECONFIG} | grep master) ; then
  echo "Testing on hypershift guest cluster"
  if (oc get authentication cluster -ojsonpath='{.spec.type}' --kubeconfig="${KUBECONFIG}" | grep OIDC);then
    echo "Testing on Cluster using external OIDC"
    USER_EMAIL="$(cat /var/run/hypershift-qe-ci-rh-sso-service-account/email)"
    export USER_EMAIL
    USER="$(cat /var/run/hypershift-qe-ci-rh-sso-service-account/rh-username)"
    export USER
    PASSWORD="$(cat /var/run/hypershift-qe-ci-rh-sso-service-account/rh-password)"
    export PASSWORD
    issuer_url="$(cat /var/run/hypershift-ext-oidc-cli/issuer-url)"
    export issuer_url
    cli_client_id="$(cat /var/run/hypershift-ext-oidc-cli/client-id)"
    export cli_client_id
    set -e
    ./console-test-azure-external-oidc.sh
  else
    ./console-test-frontend-hypershift.sh || true
  fi
else
  export E2E_RUN_TAGS="${E2E_RUN_TAGS}"
  echo "E2E_RUN_TAGS is: ${E2E_RUN_TAGS}"
  ## determine if running against managed service or smoke scenarios
  if [[ $E2E_RUN_TAGS =~ @osd_ccs|@rosa ]] ; then
    echo "Testing against online cluster"
    ./console-test-managed-service.sh || true
  elif [[ $E2E_RUN_TAGS =~ @level0 ]]; then
    echo "only run level0 scenarios"
    ./console-test-frontend.sh --tags @level0 || true
  # if the TYPE is ui, then it's a job specific for UI, run full tests
  # or else, we run smoke tests to balance coverage and cost
  elif [[ "X${E2E_TEST_TYPE}X" == 'XuiX' ]]; then
    echo "Testing on normal cluster"
    ./console-test-frontend.sh || true
  elif [[ "X${E2E_RUN_TAGS}X" == 'XNetwork_ObservabilityX' ]]; then
    # not using --grepTags here since cypress in 4.12 doesn't have that plugin
    echo "Running Network_Observability tests"
    ./console-test-frontend.sh --spec tests/netobserv/* || true
  elif [[ $E2E_RUN_TAGS =~ @wrs ]]; then
    # WRS specific testing
    echo 'WRS testing'
    ./console-test-frontend.sh --tags @wrs || true
  elif [[ $E2E_TEST_TYPE == 'ui_destructive' ]]; then
    echo 'Running destructive tests'
    ./console-test-frontend.sh --tags @destructive || true
  else
    echo "only run smoke scenarios"
    ./console-test-frontend.sh --tags @smoke || true
  fi
fi

# summarize test results
echo "Summarizing test results..."
failures=0 errors=0 skipped=0 tests=0
grep -r -E -h -o 'testsuite[^>]+' "${ARTIFACT_DIR}/gui_test_screenshots/console-cypress.xml" 2>/dev/null | tr -d '[A-Za-z="_]' > /tmp/zzz-tmp.log
while read -a row ; do
    # if the last ARG of command `let` evaluates to 0, `let` returns 1
    let errors+=${row[0]} failures+=${row[1]} skipped+=${row[2]} tests+=${row[3]} || true
done < /tmp/zzz-tmp.log

TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
cat > "${TEST_RESULT_FILE}" <<- EOF
cypress:
  type: openshift-extended-web-tests
  total: $tests
  failures: $failures
  errors: $errors
  skipped: $skipped
EOF

if [ $((failures)) != 0 ] ; then
    echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
    readarray -t failingscenarios < <(find "${ARTIFACT_DIR}" -name 'cypress_report*.json' -exec yq '.results[].suites[].tests[] | select(.fail == true) | .fullTitle' {} \; | sort --unique)
    for (( i=0; i<${#failingscenarios[@]}; i++ )) ; do
        echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
    done
fi
cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true
