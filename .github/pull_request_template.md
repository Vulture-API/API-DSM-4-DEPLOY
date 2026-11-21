## Work Item

<!-- Ex: SCRUM-531 -->

Closes SCRUM-

## O que foi feito

-

## Como testar

1.

## Impacto em produção

- [ ] Muda o que roda na EC2 (`scripts/`, `aws/docker-compose.aws.yml`, `aws/nginx.aws.conf`)
- [ ] Muda recurso na AWS (CloudFormation/IAM): passo manual descrito em `docs/mudancas-aws.md`
- [ ] Muda secrets/variables do environment `production`

## Checklist (DoD)

- [ ] A branch contém a chave `SCRUM-XX`
- [ ] Commits com a chave do Jira na mensagem
- [ ] CI verde (workflows, scripts, IaC, Compose/Nginx, segredos)
- [ ] Nenhum segredo, chave ou `.env` versionado
- [ ] Documentação atualizada, se aplicável
- [ ] Code Review solicitado a outro Developer
