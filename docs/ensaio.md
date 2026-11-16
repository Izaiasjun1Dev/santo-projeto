# Ensaio

## Pré-checagem

Feita em 16/11, perfil `default`, região `us-east-1`.

- **Permissão:** `aws eks list-clusters --region us-east-1` devolveu `{"clusters": []}`, sem erro. O usuário do perfil tem `AdministratorAccess`.
- **Bloqueio de acesso público do S3 (conta):** `aws s3control get-public-access-block` deu `NoSuchPublicAccessBlockConfiguration`, ou seja, desligado. O módulo `site` fica.
- **`scripts/conferir.sh` antes de tudo:** `nada sobrando`, `saida=0` (a conta só tinha a VPC padrão).
- **Ferramentas:** aws-cli 2.37.12, Terraform 1.17.2, kubectl 1.36.1, Docker 29.9.3 (Mac arm64), Node 26.13.0.

## Local

## kind

## AWS

Ensaio técnico em 16/11, das 17:53 às 19:00, em duas rodadas completas. Versões resolvidas: provider aws 6.73.0, módulo vpc 6.7.3, módulo eks 21.29.0, Kubernetes 1.37.

### Rodada 1: roteiro inteiro

| Etapa | Resultado | Tempo |
|---|---|---|
| `scripts/preparar.sh`, 1ª tentativa | Falhou no plan: `Invalid count argument` no `data "aws_eks_cluster_versions"` do node group (módulo eks 21.x sem `kubernetes_version`). Nada foi criado. Correção abaixo. | 6 s |
| `scripts/preparar.sh`, 2ª tentativa | `saida=0`, 60 recursos, dois nós `Ready`, resumo com cluster, ECR, bucket e site | **17 min 10 s** |
| ↳ cluster EKS (`aws_eks_cluster`) | | 11 min 16 s |
| ↳ node group | | 2 min 10 s |
| ↳ NAT Gateway | | 1 min 36 s |
| Parte 1: `terraform plan` | `No changes.` | 8 s |
| Parte 1: `terraform output` | `bucket_site`, `nome_cluster`, `repositorios` (`back = <conta>.dkr.ecr.us-east-1.amazonaws.com/back`), `url_site` | segundos |
| Parte 1: `repositorios = ["back", "teste-aluno"]`, `plan` | `Plan: 1 to add` | 7 s |
| Parte 1: `apply` | `Resources: 1 added`; repositório `teste-aluno` aparece no ECR | 9 s |
| Parte 1: `git checkout` do `.tfvars` e `apply` | `Plan: 0 to add, 0 to change, 1 to destroy`, `1 destroyed` | 9 s |
| Parte 2, passo 1: `kubectl apply -f back/k8s/` | 2 pods `Running` em 5 s, sem `exec format error` | 5 s |
| Parte 2, passo 2: `kubectl get service back` | `EXTERNAL-IP` com o DNS do load balancer na hora (Classic Load Balancer, sem configuração extra) | o endereço respondeu **103 s** depois do `apply` |
| Parte 2, passo 3: `scale --replicas=6` | 6 pods `Running`, 3 em cada nó | segundos |
| Parte 2, passo 4: `curl` 5 vezes em laço | **3 nomes de pod diferentes** em 5 chamadas | |
| Parte 2, passo 5: `npm install` + `npm run build` com `VITE_API_URL=http://<LB>` | `dist/` com a URL do LB no JS | 2 s |
| Parte 2, passo 6: `aws s3 sync dist/ s3://<bucket_site> --delete` | site responde 200; CORS `access-control-allow-origin: *` | 4 s |
| Parte 2, passo 7: `kubectl delete pod <o pod que respondeu>` | substituto `Running` em 4 s; total continua 6; a API segue respondendo | 4 s |
| Parte 2, passo 8: v2 (build amd64 + push `:v2` + `set image`) | troca em 25 s; em 60 chamadas com `curl` a cada 0,5 s as mensagens `versao 1` e `versao 2` se alternaram durante a troca, nenhuma falhou | build+push 5 s (cache), troca 25 s |
| Parte 2, passo 9: `kubectl rollout undo deployment/back` | volta à `v1` (imagem `:v1`); `obter_saudacao.py` restaurado com `git checkout` | 15 s |
| `scripts/destruir.sh` | LB removido antes do destroy, `Destroy complete! Resources: 60 destroyed.`, `nada sobrando`, `saida=0`, `deployment.yaml` restaurado | **12 min 36 s** |
| ↳ node group / cluster / NAT | | 8 min 12 s / 3 min 13 s / 1 min 1 s |
| `scripts/destruir.sh` de novo | `AVISO: cluster santo-projeto não encontrado ou inacessível; pulando o kubectl.`, `No changes. No objects need to be destroyed.`, `nada sobrando`, `saida=0` | 10 s |

O clique em "Chamar a API" desta rodada foi conferido por `curl` (o Chrome mostrou uma página de erro na primeira visita; na rodada 2 o mesmo endereço abriu normalmente e o clique foi feito no navegador).

### Rodada 2: do zero, com as versões dos módulos fixadas

| Etapa | Resultado | Tempo |
|---|---|---|
| `scripts/preparar.sh` | `saida=0`, dois nós `Ready` | **15 min 11 s** (cluster 11 min 28 s, node group 1 min 49 s) |
| Extra: `kubectl apply`, `scale --replicas=6`, build e `sync` do front | LB respondeu 85 s depois do `apply` | ~3 min |
| Extra: abrir a `url_site` no Chrome e clicar em "Chamar a API" duas vezes | lista com `Ola, turma! Esta e a versao 1. Respondido por back-…-sp48k.` (as duas vezes o mesmo pod: o navegador reaproveita a conexão, como o Roteiro avisa) | |
| `scripts/destruir.sh` | LB removido, `Destroy complete! Resources: 60 destroyed.`, `nada sobrando`, `saida=0`, `deployment.yaml` restaurado | **12 min 44 s** |

### O que falhou e como foi corrigido

1. **`terraform apply` falhava no plan com `Invalid count argument`** (`.terraform/modules/eks.eks/modules/eks-managed-node-group/main.tf`, `data "aws_eks_cluster_versions"`). Sem `kubernetes_version`, o node group do módulo eks 21.x depende da versão do cluster, que só existe depois do apply. Correção: `kubernetes_version = "1.37"` em `infra/modules/eks/main.tf` (1.37 é a versão padrão do EKS hoje, em suporte padrão).
2. **Versões dos módulos fixadas** depois do ensaio: `version = "21.29.0"` (eks) e `version = "6.7.3"` (vpc), no lugar de `~> 21.0` e `~> 6.0`. A rodada 2 já subiu com elas.

Nada mais falhou: `preparar.sh`, `destruir.sh` e `conferir.sh` rodaram sem alteração.

### Custo estimado

Preços on-demand em `us-east-1` (AWS Pricing API, 16/11): EKS US$ 0,10/h por cluster; t3.medium US$ 0,0416/h; NAT Gateway US$ 0,045/h + US$ 0,045/GB; Classic Load Balancer US$ 0,025/h (hora ou fração); IPv4 público US$ 0,005/h por endereço; gp3 US$ 0,08/GB-mês (2 discos de 20 GB). Por hora, com tudo de pé: cerca de **US$ 0,27/h** (EKS 0,10 + nós 0,083 + NAT 0,05 com o IP + LB 0,035 com 2 IPs + discos e chave KMS < 0,01).

- **Este ensaio:** infraestrutura de pé por ~35 min na rodada 1 e ~30 min na rodada 2, LB por ~5 min em cada. Contando hora cheia para EKS, NAT e LB (cobrança por hora ou fração), mais tráfego de NAT (pull de imagens, < 1 GB) e logs do plano de controle: **menos de US$ 1** no total.
- **Dia da aula (~2 h de pé, LB por ~1 h):** EKS 0,20 + nós 0,17 + NAT 0,10 + LB 0,035 + IPs, discos, NAT por GB e logs ~0,10 = **cerca de US$ 0,60 a US$ 1**. Esquecer tudo ligado por um dia custa ~US$ 6,50.

## Mudanças para os docs

- **Roteiro › Código: infra › Módulo eks:** o `modules/eks/main.tf` ganhou a linha `kubernetes_version     = "1.37"` logo abaixo de `name`, e `version = "~> 21.0"` virou `version = "21.29.0"`.
- **Roteiro › Código: infra › Módulo rede:** `version = "~> 6.0"` virou `version = "6.7.3"` (o `~> 6.0` do provider aws na raiz continua igual).
- **Roteiro › Preparação:** o `preparar.sh` levou 15 a 17 min (o EKS sozinho, 11 min); "uns 15 minutos" continua valendo, mas vale dizer "15 a 20 minutos". O `destruir.sh` leva ~13 min.
- **Roteiro › Parte 2, passo 2:** o endereço respondeu em 85 a 103 s, menos que os "2 a 3 minutos" do texto; manter a orientação de seguir para o passo 3. O load balancer criado é um Classic Load Balancer, sem configuração extra no cluster (o plano B do `port-forward` não foi necessário na AWS).
- **Roteiro › Parte 2, passo 9:** o `kubectl rollout undo` (kubectl 1.36) imprime um aviso sobre `last-applied-configuration` porque o deployment foi criado com `kubectl apply`. É inofensivo; vale avisar para ninguém se assustar no projetor.
- **Roteiro › Parte 2, passo 6:** a página do front usa o estilo padrão do navegador e fica pequena no projetor; dar zoom no navegador (Cmd +) antes de clicar.

## Rodada do professor
