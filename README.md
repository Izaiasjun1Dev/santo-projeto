# Santo Projeto

Projeto da aula de infraestrutura: uma API e um site React que você sobe na AWS com Terraform e Kubernetes (EKS).

## Estrutura

```
santo-projeto/
├── infra/      # Terraform: raiz + modules/{rede,ecr,eks,site} + envs/aula.tfvars
├── back/       # API FastAPI em quatro camadas + Dockerfile + k8s/
├── front/      # React (Vite) em quatro camadas
├── scripts/    # preparar.sh, publicar-imagens.sh, destruir.sh, conferir.sh
├── docs/       # especificação e referência do Roteiro
├── README.md
└── .gitignore
```

## Roteiro principal

Siga o **Guia do participante**: https://claude.ai/artifact/84trFcnbNVicMbhbnDAq7n

Ele é o roteiro da aula. Este README só mostra como preparar o ambiente.

## Caminho sem custo: kind no WSL

Execute os comandos abaixo no **terminal WSL (bash)**, não no PowerShell nem no cmd.

1. Clone o repositório:

   ```bash
   git clone https://github.com/USUARIO-GITHUB/santo-projeto.git
   cd santo-projeto
   ```

2. Crie o cluster com a imagem de nó do GHCR:

   ```bash
   kind create cluster --name aula --image ghcr.io/USUARIO-GITHUB/kindest-node:TAG-DO-KIND
   ```

3. Siga os sete passos do Guia. Os comandos principais são:

   ```bash
   kubectl create deployment back --image=ghcr.io/USUARIO-GITHUB/santo-projeto-back:v1 --replicas=2 --port=8000
   kubectl port-forward deployment/back 8000:8000      # deixe rodando em outro terminal
   curl localhost:8000/api/saudacao
   kubectl scale deployment back --replicas=6
   kubectl delete pod NOME                              # NOME de um pod listado em: kubectl get pods
   kubectl set image deployment/back '*=ghcr.io/USUARIO-GITHUB/santo-projeto-back:v2'
   kubectl rollout undo deployment/back
   ```

   O `port-forward` cai quando o pod que ele usa é apagado ou substituído (por exemplo, no `delete pod` ou no `set image`). Nesse caso, rode o comando de novo.

## Atenção: custo na AWS

Não rode `terraform apply`. O cluster EKS e os demais recursos são cobrados por hora e podem gerar custo sem você perceber. Se tiver conta AWS, `terraform plan` é seguro, porque só mostra o que seria criado.
