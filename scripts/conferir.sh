#!/bin/bash
# Confere se sobrou algo do projeto na conta (somente leitura: describe/list/get).
# Saída: 0 = nada sobrando, 1 = sobrou algo do projeto, 2 = uma checagem falhou.
# Compatível com o bash 3.2 do macOS. Nunca imprime credenciais.

REGIAO="us-east-1"
PROJETO="santo-projeto"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$RAIZ/infra/envs/aula.tfvars"

ERRO="$(mktemp)"
trap 'rm -f "$ERRO"' EXIT

# chamar <checagem> <comando aws...>: guarda o JSON em $R; se falhar, sai com 2.
chamar() {
  local nome="$1"
  shift
  R="$(aws --region "$REGIAO" --output json "$@" 2>"$ERRO" </dev/null)" || {
    echo "falha na checagem: $nome" >&2
    head -n 1 "$ERRO" >&2
    exit 2
  }
  [ -n "$R" ] || R='{}'
}

PROJ=""    # sobras do projeto, uma por linha
OUTROS=""  # recursos sem a marca do projeto, uma por linha

# registrar: lê linhas "P<TAB>texto" ou "O<TAB>texto" do stdin.
registrar() {
  local tipo texto
  while IFS=$'\t' read -r tipo texto; do
    [ -n "$texto" ] || continue
    if [ "$tipo" = "P" ]; then
      PROJ="$PROJ$texto"$'\n'
    else
      OUTROS="$OUTROS$texto"$'\n'
    fi
  done
}

# Funções jq usadas em várias checagens.
DEFS='
def tem($k): (.Tags // []) | any(.Key == $k);
def tag($k): ((.Tags // []) | map(select(.Key == $k)) | .[0].Value) // "";
def doprojeto: (tag("Projeto") == $projeto) or tem("kubernetes.io/cluster/" + $projeto);
def emvpc($v): ($v != null) and (($vpcs | split("\n") | index($v)) != null);
'

# Repositórios ECR do projeto, lidos de infra/envs/aula.tfvars.
[ -f "$TFVARS" ] || { echo "falha: não achei $TFVARS" >&2; exit 2; }
REPOS="$(grep '^repositorios' "$TFVARS" | grep -o '"[^"]*"' | tr -d '"')"
[ -n "$REPOS" ] || { echo "falha: sem 'repositorios' em $TFVARS" >&2; exit 2; }

# VPCs do projeto (para NAT, EIP, instâncias e load balancers sem tag).
chamar "ec2 describe-vpcs" ec2 describe-vpcs --filters "Name=tag:Projeto,Values=$PROJETO"
VPCS="$(echo "$R" | jq -r '.Vpcs[].VpcId')"

# EC2 não terminadas.
chamar "ec2 describe-instances" ec2 describe-instances \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down"
registrar <<< "$(echo "$R" | jq -r --arg projeto "$PROJETO" --arg vpcs "$VPCS" "$DEFS"'
  .Reservations[].Instances[]
  | (doprojeto or emvpc(.VpcId)) as $p
  | (if $p then "P" else "O" end) + "\tec2: " + .InstanceId
    + (if tag("Name") != "" then " (" + tag("Name") + ")" else "" end)')"

# Load balancers v2 (ALB/NLB).
chamar "elbv2 describe-load-balancers" elbv2 describe-load-balancers
LBS="$(echo "$R" | jq -r '.LoadBalancers[] | [.LoadBalancerArn, .LoadBalancerName, (.VpcId // "")] | @tsv')"
while IFS=$'\t' read -r arn nome vpc; do
  [ -n "$arn" ] || continue
  chamar "elbv2 describe-tags ($nome)" elbv2 describe-tags --resource-arns "$arn"
  m="$(echo "$R" | jq -r --arg projeto "$PROJETO" --arg vpcs "$VPCS" --arg vpc "$vpc" "$DEFS"'
    (.TagDescriptions[0] // {}) | if doprojeto or emvpc($vpc) then "P" else "O" end')"
  registrar <<< "$m"$'\t'"load balancer v2: $nome"
done <<< "$LBS"

# Load balancers clássicos.
chamar "elb describe-load-balancers" elb describe-load-balancers
LBS="$(echo "$R" | jq -r '.LoadBalancerDescriptions[] | [.LoadBalancerName, (.VPCId // "")] | @tsv')"
while IFS=$'\t' read -r nome vpc; do
  [ -n "$nome" ] || continue
  chamar "elb describe-tags ($nome)" elb describe-tags --load-balancer-names "$nome"
  m="$(echo "$R" | jq -r --arg projeto "$PROJETO" --arg vpcs "$VPCS" --arg vpc "$vpc" "$DEFS"'
    (.TagDescriptions[0] // {}) | if doprojeto or emvpc($vpc) then "P" else "O" end')"
  registrar <<< "$m"$'\t'"load balancer clássico: $nome"
done <<< "$LBS"

# NAT Gateways não deleted.
chamar "ec2 describe-nat-gateways" ec2 describe-nat-gateways \
  --filter "Name=state,Values=pending,available,deleting,failed"
NATS="$R"
registrar <<< "$(echo "$NATS" | jq -r --arg projeto "$PROJETO" --arg vpcs "$VPCS" "$DEFS"'
  .NatGateways[]
  | (tag("Projeto") == $projeto or emvpc(.VpcId)) as $p
  | (if $p then "P" else "O" end) + "\tnat gateway: " + .NatGatewayId')"
# Alocações de EIP usadas por NATs do projeto (EIP sem tag, mas na VPC do projeto).
ALOCS="$(echo "$NATS" | jq -r --arg projeto "$PROJETO" --arg vpcs "$VPCS" "$DEFS"'
  .NatGateways[] | select(tag("Projeto") == $projeto or emvpc(.VpcId))
  | .NatGatewayAddresses[]?.AllocationId')"

# Elastic IPs.
chamar "ec2 describe-addresses" ec2 describe-addresses
registrar <<< "$(echo "$R" | jq -r --arg projeto "$PROJETO" --arg alocs "$ALOCS" "$DEFS"'
  .Addresses[] | (.AllocationId // "") as $id
  | (tag("Projeto") == $projeto or (($alocs | split("\n") | index($id)) != null)) as $p
  | (if $p then "P" else "O" end) + "\telastic ip: " + (.AllocationId // .PublicIp)
    + " (" + (.PublicIp // "") + ")"')"

# Cluster EKS.
chamar "eks list-clusters" eks list-clusters
registrar <<< "$(echo "$R" | jq -r --arg projeto "$PROJETO" '
  .clusters[]? | (if . == $projeto then "P" else "O" end) + "\tcluster eks: " + .')"

# Repositórios ECR.
chamar "ecr describe-repositories" ecr describe-repositories
registrar <<< "$(echo "$R" | jq -r --arg repos "$REPOS" '
  .repositories[]? | .repositoryName as $n
  | (if (($repos | split("\n") | index($n)) != null)
    then "P" else "O" end) + "\trepositório ecr: " + .repositoryName')"

# Buckets S3.
chamar "s3api list-buckets" s3api list-buckets
registrar <<< "$(echo "$R" | jq -r --arg projeto "$PROJETO" '
  .Buckets[]? | (if (.Name | startswith($projeto)) then "P" else "O" end)
    + "\tbucket s3: " + .Name')"

# Grupos de log do EKS.
chamar "logs describe-log-groups" logs describe-log-groups --log-group-name-prefix "/aws/eks/"
registrar <<< "$(echo "$R" | jq -r --arg projeto "$PROJETO" '
  .logGroups[]? | (if (.logGroupName | startswith("/aws/eks/" + $projeto + "/")) or
    .logGroupName == "/aws/eks/" + $projeto then "P" else "O" end)
    + "\tgrupo de log: " + .logGroupName')"

# Aliases KMS (aliases alias/aws/* são das chaves gerenciadas pela AWS e ficam de fora).
chamar "kms list-aliases" kms list-aliases
ALIASES="$(echo "$R" | jq -r '.Aliases[]? | select(.AliasName | startswith("alias/aws/") | not)
  | [.AliasName, (.TargetKeyId // "")] | @tsv')"
while IFS=$'\t' read -r alias chave; do
  [ -n "$alias" ] || continue
  if [[ "$alias" == alias/eks/$PROJETO* ]]; then
    estado=""
    if [ -n "$chave" ]; then
      chamar "kms describe-key ($alias)" kms describe-key --key-id "$chave"
      estado="$(echo "$R" | jq -r '.KeyMetadata.KeyState')"
    fi
    if [ "$estado" != "PendingDeletion" ]; then
      PROJ="${PROJ}alias kms: $alias"$'\n'
    fi
  else
    OUTROS="${OUTROS}alias kms: $alias"$'\n'
  fi
done <<< "$ALIASES"

# Relatório.
if [ -n "$OUTROS" ]; then
  echo "outros recursos na região (sem a marca do projeto, não contam):"
  printf '%s' "$OUTROS" | sed 's/^/  /'
fi
if [ -n "$PROJ" ]; then
  echo "sobrou do projeto:"
  printf '%s' "$PROJ"
  exit 1
fi
echo "nada sobrando"
exit 0
