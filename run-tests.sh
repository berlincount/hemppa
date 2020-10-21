#!/bin/bash

if [ -z "$(which docker-compose)" ]; then echo "ERROR: you need docker-compose"; exit 1; fi
if [ -z "$(which openssl)" ];        then echo "ERROR: you need the openssl binary"; exit 1; fi
if [ -z "$(which curl)" ];           then echo "ERROR: you need the curl binary"; exit 1; fi
if [ -z "$(which jq)" ];             then echo "ERROR: you need the jq binary"; exit 1; fi

if [ $UID -ne 0 ]; then
  echo "ERROR: This script needs to be run with UID 0 (e.g. via fakeroot)"
  exit 1
fi

function finish {
  echo "================================================================================"
  echo "INFO: Shutting down Synapse"
  docker-compose -f docker-testing.yml logs synapse > testserver-data/synapse.log
  docker-compose -f docker-testing.yml logs hemppa > testbot-data/hemppa.log
  docker-compose -f docker-testing.yml logs matrix-commander > testclient-data/matrix-commander.log
  # NOTE: if we're just stopping and not removing the logs would accumulate
  docker-compose -f docker-testing.yml rm -fsv
}
trap finish EXIT

echo "INFO: Adjusting testclient data folder"
rm -rf testclient-data
mkdir -p testclient-data/store
chmod a+rwx testclient-data

echo "INFO: Adjusting testbot data folder"
rm -rf testbot-data
mkdir -p testbot-data/config
touch testbot-data/credentials.json
touch testbot-data/token.pickle
cp config/logging.yml testbot-data/config
# enable more runtime debug info
sed -i -e's/INFO/DEBUG/' testbot-data/config/logging.yml
chmod a+rwx testbot-data testbot-data/config
chmod a+rw testbot-data/* testbot-data/config/*

echo "INFO: Adjusting testserver data folder"
mkdir -p testserver-data
chmod a+rwx testserver-data
rm -vrf testserver-data/media_store testserver-data/homeserver.db

echo "INFO: Generating TLS certificates and crypto data if necessary"
set -e
for DIR in root-ca intermediate; do

  mkdir -p testserver-data/$DIR
  cd testserver-data/$DIR
  mkdir -p certs crl newcerts private
  cd ../..

  [ -f testserver-data/$DIR/serial ] || echo 1234 > testserver-data/$DIR/serial
  [ -f testserver-data/$DIR/index.txt ] || touch testserver-data/$DIR/index.txt testserver-data/$DIR/index.txt.attr

  [ -f testserver-data/$DIR/openssl.cnf ] || echo '
[ ca ]
default_ca     = CA_default
[ CA_default ]
dir            = 'testserver-data/$DIR'   # Where everything is kept
certs          = $dir/certs               # Where the issued certs are kept
crl_dir        = $dir/crl                 # Where the issued crl are kept
database       = $dir/index.txt           # database index file.
new_certs_dir  = $dir/newcerts            # default place for new certs.
certificate    = $dir/cacert.pem          # The CA certificate
serial         = $dir/serial              # The current serial number
crl            = $dir/crl.pem             # The current CRL
private_key    = $dir/private/ca.key.pem  # The private key
RANDFILE       = $dir/.rnd                # private random number file
nameopt        = default_ca
certopt        = default_ca
policy         = policy_match
default_days   = 365
default_md     = sha256

[ policy_match ]
countryName            = optional
stateOrProvinceName    = optional
organizationName       = optional
organizationalUnitName = optional
commonName             = supplied
emailAddress           = optional

[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]

[v3_req]
basicConstraints = CA:TRUE

[SAN_synapse]
subjectAltName = DNS:synapse
' > testserver-data/$DIR/openssl.conf
done

[ -f testserver-data/root-ca/private/ca.key ] || openssl genrsa -out testserver-data/root-ca/private/ca.key 2048
[ -f testserver-data/root-ca/certs/ca.crt ]   || openssl req -config testserver-data/root-ca/openssl.conf -new -x509 -days 3650 -key testserver-data/root-ca/private/ca.key -sha256 -extensions v3_req -out testserver-data/root-ca/certs/ca.crt -subj '/CN=Root CA'

[ -f testserver-data/intermediate/private/intermediate.key ] || openssl genrsa -out testserver-data/intermediate/private/intermediate.key 2048
[ -f testserver-data/intermediate/certs/intermediate.csr ]   || openssl req -config testserver-data/intermediate/openssl.conf -sha256 -new -key testserver-data/intermediate/private/intermediate.key -out testserver-data/intermediate/certs/intermediate.csr -subj '/CN=Intermediate CA'
[ -f testserver-data/intermediate/certs/intermediate.crt ]   || openssl ca -batch -config testserver-data/root-ca/openssl.conf -keyfile testserver-data/root-ca/private/ca.key -cert testserver-data/root-ca/certs/ca.crt -extensions v3_req -notext -md sha256 -in testserver-data/intermediate/certs/intermediate.csr -out testserver-data/intermediate/certs/intermediate.crt

[ -f testserver-data/synapse.key ] || openssl req -config testserver-data/intermediate/openssl.conf -new -keyout testserver-data/synapse.key -out testserver-data/synapse.csr -days 365 -nodes -subj "/CN=synapse" -reqexts SAN_synapse -extensions SAN_synapse -newkey rsa:2048
[ -f testserver-data/synapse.crt ] || openssl ca -batch -config testserver-data/intermediate/openssl.conf -extensions SAN_synapse -keyfile testserver-data/intermediate/private/intermediate.key -cert testserver-data/intermediate/certs/intermediate.crt -out testserver-data/synapse.crt -infiles testserver-data/synapse.csr

cat testserver-data/root-ca/certs/ca.crt testserver-data/intermediate/certs/intermediate.crt > testserver-data/fullchain.pem

# make it possible for Synapse to read the key ...
chmod a+r testserver-data/synapse.key
set +e

cat testserver-data/root-ca/certs/ca.crt testserver-data/intermediate/certs/intermediate.crt > testserver-data/fullchain.pem

# make it possible for Synapse to read the key ...
chmod a+r testserver-data/synapse.key
set +e


echo "INFO: Starting Synapse in the background"
docker-compose -f docker-testing.yml up -d synapse

echo -n "INFO: Waiting for Synapse to come up "
COUNTER=600
while ! curl -s -o /dev/null 127.0.0.1:18008; do
  sleep 0.1
  (( COUNTER=COUNTER-1 ))
  [ $(( COUNTER % 20 )) -eq 0 ] && echo -n .
  if [ "${COUNTER}" -le 0 ]; then
      echo
      echo "ERROR: Synapse took more than a minute to start up"
      exit 1
  fi
done
echo

echo "INFO: Creating users for testing"
if ! curl -fso testbot-data/botuser.json -XPOST -d '{"username":"botuser", "password":"botpass", "auth": {"type":"m.login.dummy"}}' "http://127.0.0.1:18008/_matrix/client/r0/register"; then echo "ERROR: failed creating botuser" ; exit 1 ; fi
if ! curl -fso testclient-data/adminuser.json -XPOST -d '{"username":"adminuser", "password":"adminpass", "auth": {"type":"m.login.dummy"}}' "http://127.0.0.1:18008/_matrix/client/r0/register"; then echo "ERROR: failed creating adminuser" ; exit 1 ; fi
if ! curl -fso testclient-data/frienduser.json -XPOST -d '{"username":"frienduser", "password":"friendpass", "auth": {"type":"m.login.dummy"}}' "http://127.0.0.1:18008/_matrix/client/r0/register"; then echo "ERROR: failed creating frienduser" ; exit 1 ; fi
if ! curl -fso testclient-data/randomuser.json -XPOST -d '{"username":"randomuser", "password":"randompass", "auth": {"type":"m.login.dummy"}}' "http://127.0.0.1:18008/_matrix/client/r0/register"; then echo "ERROR: failed creating randomuser" ; exit 1 ; fi

echo "INFO: Bringing up testing hemppa"
echo '
BOT_OWNERS=@adminuser:synapse
MATRIX_SERVER=https://synapse:8448
MATRIX_USER=@botuser:synapse
MATRIX_ACCESS_TOKEN='$(jq -r < testbot-data/botuser.json .access_token)'
' > testbot-data/environment
docker-compose -f docker-testing.yml --env-file testbot-data/environment up -d hemppa

echo "================================================================================"
echo "INFO: Starting tests"
jq < testclient-data/adminuser.json > testclient-data/adminuser-credentials.json '{"access_token":.access_token,"device_id":.device_id,"homeserver":"https://synapse:8448","user_id":"@adminuser:synapse","room_id":""}'

# our test wrapper - matrix-commander isn't optimal, but does the job.
TST=0
TSTSTR=$(printf %02d $TST)
mc_admin() {
  docker-compose -f docker-testing.yml run --rm matrix-commander --credentials /data/adminuser-credentials.json "$@" 2>&1 | tee testclient-data/adminuser-tst-${TSTSTR}.txt
  # FIXME: matrix-commander has unreliable exit status
  #[[ "${PIPESTATUS[@]}" =~ [^0\ ] ]] && echo 'ERROR:   ... error exit!' && exit 1
  ((TST+=1))
  TSTSTR=$(printf %02d $TST)
}

BOTUSR=$(jq -r < testbot-data/botuser.json .user_id)
BOTDEV=$(jq -r < testbot-data/botuser.json .device_id)

echo "INFO: [${TSTSTR}] Getting current messages for '@adminuser:synapse' ..."
mc_admin --listen-self --listen once
echo "INFO: [${TSTSTR}] Letting '@adminuser:synapse' verify '@botuser:synapse' ..."
mc_admin --verify emoji
echo "INFO: [${TSTSTR}] Getting current messages for '@adminuser:synapse' ..."
mc_admin --listen-self --listen once
echo "INFO: [${TSTSTR}] Creating '#testroom:synapse'"
mc_admin --room-create 'testroom' --room '#testroom:synapse' -m "Message ${TSTSTR}"
echo "INFO: [${TSTSTR}] Inviting '@botuser:synapse' to '#testroom:synapse'"
mc_admin --room-invite '@botuser:synapse' --room '#testroom:synapse' -m "Message ${TSTSTR}"
echo "INFO: [${TSTSTR}] Sending a message to '#testroom:synapse'"
mc_admin --room '#testroom:synapse' -m "Message ${TSTSTR}"
echo "INFO: [${TSTSTR}] Getting current messages for '@adminuser:synapse' ..."
mc_admin --listen-self --listen once
echo "INFO: [--] Pausing 2s"
sleep 2
echo "INFO: [${TSTSTR}] Sending a message to '#testroom:synapse'"
mc_admin --room '#testroom:synapse' -m "Message ${TSTSTR}"
echo "INFO: [${TSTSTR}] Getting current messages for '@adminuser:synapse' ..."
mc_admin --listen-self --listen once
