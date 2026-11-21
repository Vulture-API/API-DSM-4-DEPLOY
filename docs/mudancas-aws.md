# Mudanças no deploy AWS — 20/11/2026

Resumo para o responsável pelo DevOps (Enrico). Já aplicado na AWS em 20/11 pelo console (Lucas).

## 1. Trust policy da role `vulture-prod-github-actions-deploy-role` (aplicado)

**Antes:** `StringLike sub = repo:Vulture-API/API-DSM-4-DEPLOY:*` (e a variante com IDs).
Qualquer branch, PR ou workflow do repo DEPLOY conseguia assumir a role de produção.

**Agora:** `StringEquals sub` com só estes valores:

```
repo:Vulture-API/API-DSM-4-DEPLOY:ref:refs/heads/main
repo:Vulture-API/API-DSM-4-DEPLOY:environment:production
repo:Vulture-API@324885289/API-DSM-4-DEPLOY@1462724427:ref:refs/heads/main
repo:Vulture-API@324885289/API-DSM-4-DEPLOY@1462724427:environment:production
```

- `ref:refs/heads/main`: mantém funcionando o workflow antigo (sem environment) até este PR entrar.
- `environment:production`: é o `sub` do workflow novo (o job de deploy usa `environment: production`).
- Depois do merge e de um deploy verde, a linha `ref:refs/heads/main` pode sair (opcional).
- Os arquivos `aws/iam-github-trust-policy.json` e `aws/cloudformation-ec2-stack.yaml` já estão iguais.
- Não existe stack do CloudFormation em us-east-1: a role foi criada à mão, então não há drift a resolver.

Como conferir: IAM → Roles → `vulture-prod-github-actions-deploy-role` → Relações de confiança.

## 2. Configuração no GitHub (fazer antes do merge)

No repo **API-DSM-4-DEPLOY**:
1. Settings → Environments → **New environment** `production`.
   - Deployment branches and tags: **Selected branches** → `main`.
   - Sem required reviewers (decisão do time).
   - (Opcional) mover para cá os secrets `AWS_ROLE_ARN`, `AWS_EC2_INSTANCE_ID` e a variable `PUBLIC_DOMAIN`. Secrets do repositório continuam funcionando.
2. Settings → Branches → regra para `main`: exigir PR e os checks do workflow **CI**.
3. Variable `PUBLIC_DOMAIN` (repo ou environment): domínio público da EC2 (ex.: `3-91-10-20.sslip.io`). O smoke test externo usa `https://PUBLIC_DOMAIN/dashboard` e `/health`. Os secrets `PROD_API_URL`/`PROD_FRONT_URL` viram opcionais.

No repo **API-DSM-4-INFRA**:
4. Secret `DEPLOY_DISPATCH_TOKEN`: PAT fine-grained (ou GitHub App) com acesso **só** ao repo API-DSM-4-DEPLOY e permissão **Actions: Read and write**. É usado para disparar o deploy depois do E2E verde na main.

## 3. O que mudou no fluxo

Antes: o deploy só rodava com push na main do DEPLOY e a EC2 publicava a ponta da main do INFRA na hora, testada ou não. Merge no INFRA não publicava nada.

Agora:
1. Merge na main do INFRA → E2E roda no push da main.
2. E2E e suítes fixadas verdes → o INFRA chama `deploy-aws.yml` com o SHA testado (`infra_sha`).
3. DEPLOY: **CI** → **gate** (o SHA está na main do INFRA e os dois jobs do E2E estão verdes) → **deploy** (SSM, environment `production`) → **smoke externo**.
4. Na EC2, `deploy-ec2.sh` faz checkout exato do SHA; se qualquer etapa falhar, volta para o commit anterior e sobe tudo de novo.

Republicar/voltar versão: Actions → *Continuous Deployment (AWS EC2)* → Run workflow → `infra_sha` (só aceita commit da main do INFRA com E2E verde).

## 4. Bugs corrigidos

| Bug | Correção |
|---|---|
| `aws ssm wait command-executed` desiste em ~100 s (com `\|\| true`) e o job falhava com o deploy ainda rodando | polling próprio até status final (até 15 min para a EC2 começar + 45 min de execução, com `executionTimeout` explícito) |
| Sem secrets, push na main ficava verde sem publicar | job falha com erro dizendo o que configurar |
| Smoke local em `127.0.0.1:80/dashboard` recebia 301 (o nginx vê o IP do gateway Docker) e passava sem testar o frontend | smoke via `docker exec` no nginx, HTTPS real com `--resolve` e `/health` |
| `/health` externo caía no Next (nginx só tinha o frontend) | `location = /health` no nginx da AWS aponta para o backend |
| Sem rollback | `trap` volta para o commit anterior do INFRA e sobe os serviços |
| `vars.PUBLIC_DOMAIN` interpolado direto no shell | passado por env e validado (hostname) no workflow e no script |
| Input `environment: staging` não fazia nada | removido |
| Bootstrap só clonava o repo DEPLOY em `/opt/vulture` em um dos caminhos, e o workflow depende dele | sempre clona/atualiza |
| `ubuntu-latest`, actions antigas | `ubuntu-24.04`, `configure-aws-credentials@v5`, CI com actionlint/shellcheck/bats/cfn-lint/checkov/gitleaks |

## 5. Riscos que continuam (não são código)

- **MQTT 1883 aberto em 0.0.0.0/0 e broker sem senha**: qualquer um pode publicar telemetria. Sugestão: senha no mosquitto e/ou restringir `AllowedMqttCidr`.
- **Migrations no Neon são manuais**: o deploy não confere se o banco já tem as migrations que a versão exige. Aplicar antes de mesclar no INFRA uma versão que dependa delas.
- O fallback por **SSH** só é usado se os secrets de SSM não existirem. Se ninguém usa, os secrets `EC2_SSH_*` podem ser apagados.
