# AgriTech — API-DSM-4-DEPLOY (Deploy Contínuo na AWS)

Repositório dedicado à **automação de infraestrutura e Deploy Contínuo (CD)** do projeto Vulture na **Amazon Web Services (AWS EC2 + Docker Compose)**.

---

## Por que este repositório é separado?

1. **Separação de Responsabilidades (GitOps):**
   - `API-DSM-4SEMESTRE-2026`: documentação geral, sprints, atas e gestão do projeto.
   - `API-DSM-4-INFRA`: composição Docker Compose, submódulos fixados da aplicação (`BACKEND`, `FRONTEND`, `RECEPCAO`, `PERSISTENCIA`, `BANCO`) e testes E2E/QA.
   - **`API-DSM-4-DEPLOY`**: exclusivamente Infraestrutura como Código (CloudFormation/IAM), scripts operacionais da EC2 e pipeline de publicação em produção.
2. **Segurança e Menor Privilégio (AWS OIDC & Secrets):**
   A Trust Policy OIDC da AWS e os Secrets de produção (`AWS_ROLE_ARN`, `AWS_EC2_INSTANCE_ID`) ficam restritos à `main` e ao environment `production` deste repositório, evitando exposição ou acionamento acidental a partir de PRs de código ou documentação em outros repositórios.
3. **Proteção de Branch e Auditoria:**
   Permite aplicar regras rígidas de aprovação na branch `main` exclusivamente para liberações em produção, mantendo histórico limpo de cada deploy.

---

## Estrutura do Repositório

- `.github/workflows/ci.yml` — CI (PR e antes de cada deploy): actionlint, shellcheck/shfmt, testes bats do `deploy-ec2.sh`, cfn-lint, checagem da trust policy, checkov, override do Compose + `nginx -t` e gitleaks (`.gitleaks.toml` libera só os valores fictícios de teste).
- `.github/workflows/deploy-aws.yml` — CD: CI → gate (commit do INFRA na main com E2E verde) → deploy via OIDC + SSM no environment `production` (fallback SSH) → smoke test externo. Disparado pelo INFRA após o E2E verde na main, por push na main deste repo ou manualmente com `infra_sha`.
- `docs/mudancas-aws.md` — Mudanças de 20/11 na AWS/GitHub e passos de configuração.
- `test/deploy-ec2.bats` — Testes das validações do script de deploy.
- `aws/cloudformation-ec2-stack.yaml` — Template CloudFormation (EC2 Ubuntu 24.04, Security Group, EBS `gp3` criptografado, Elastic IP, IAM Role EC2 e IAM OIDC Role).
- `aws/iam-github-trust-policy.json` e `aws/iam-github-permissions-policy.json` — Políticas IAM avulsas para criação manual.
- `aws/docker-compose.aws.yml` — Override de produção para o `docker-compose.yml` do `API-DSM-4-INFRA`.
- `scripts/ec2-bootstrap.sh` — Preparação inicial da instância EC2 (swap 2 GB, Docker, rotação de logs, SSM, clone do `API-DSM-4-INFRA` e geração do `.env`).
- `scripts/deploy-ec2.sh` — Script executado na EC2 durante o deploy: checkout exato do `INFRA_SHA` e submódulos fixados, certificado HTTPS, build/up do Compose, `telemetry.py activate`, smoke tests locais e rollback automático para o commit anterior em caso de falha.

---

## Guia Completo

Consulte o passo a passo detalhado de provisionamento, configuração de Secrets e operação em [`API-DSM-4SEMESTRE-2026/docs/devops/deploy_automatico_aws.md`](https://github.com/Vulture-API/API-DSM-4SEMESTRE-2026/blob/dev/docs/devops/deploy_automatico_aws.md).
