# Acesso ao laboratório

Abra diretamente no navegador de um computador com conectividade IPv6:

| Aplicação | URL |
|---|---|
| Grafana | http://[2001:48d0:6031:1991:f816:3eff:fecd:5bec]:30000/d/cpu-energy-lab |
| Chaos Mesh | http://[2001:48d0:6031:1991:f816:3eff:fecd:5bec]:30001 |

Grafana usa NodePort TCP **30000**; Chaos Dashboard usa **30001**, ambos dual-stack.
Autorize essas portas no grupo de segurança da nuvem e no firewall da VM somente
para o IPv6/rede do seu computador. O instalador não altera esses firewalls.
O acesso direto é HTTP; para transportar as credenciais por SSH, use a alternativa abaixo.
Prometheus e Kepler continuam internos.

## Alternativa com túnel SSH

Na VM: `./application_access.sh` (neste diretório). Mantenha aberto.
No computador com navegador, abra outro terminal e conecte por SSH:

```bash
ssh -N -L 3000:127.0.0.1:3000 -L 2333:127.0.0.1:2333 -L 9090:127.0.0.1:9090 ubuntu@2001:48d0:6031:1991:f816:3eff:fecd:5bec
```

Acrescente as opções de chave/bastion que você já usa para entrar nesta VM.
No navegador do seu computador:

| Aplicação | URL |
|---|---|
| Grafana | http://localhost:3000/d/cpu-energy-lab |
| Chaos Mesh | http://localhost:2333 |
| Prometheus | http://localhost:9090 |

Grafana: usuário `admin`; senha em `credentials/grafana-password.txt`.
Chaos Mesh: token em `credentials/chaos-token.txt`; renove com `./renew_chaos_token.sh`.
O servidor pode limitar a validade solicitada de 24 horas.

Na janela do Chaos Mesh, preencha **Name** com `default-manager` e **Token** com o token inteiro.
Para consultar os dois logins e renovar automaticamente um token ausente ou próximo de expirar,
execute `./application_install.sh --credentials` no diretório onde está o instalador,
com o mesmo `APP_BUILD_DIR` usado na instalação, caso tenha sido personalizado.
Para forçar a renovação, use `--renew-chaos-token`. Essas opções não reinstalam aplicações.
A geração/renovação é automática ao executar o comando; colar o token no navegador continua manual.

## Experimento pelo navegador

Abra Grafana e Chaos Dashboard em abas separadas. Observe aproximadamente 1 minuto de baseline.
No Chaos Dashboard: NEW EXPERIMENT → STRESS TEST → CPU.
Escolha namespace `default`, label `app=ubuntu-test`, container `ubuntu-test`, modo `one`,
workers `3`, load `80`, duração `120s`. Use nome `cpu-stress-ubuntu`.
Submeta para iniciar. A carga termina ao completar o período; acompanhe o estado na interface.
O arquivo `cpu-stress.yaml` contém o mesmo experimento para referência/importação.
O instalador somente valida esse YAML no servidor; não aplica o experimento.

O limite de 4 CPUs protege a capacidade restante da VM de 8 vCPUs. Três workers a 80% visam
aproximadamente 2,4 núcleos de carga, sujeitos ao escalonamento e às outras aplicações.
O gráfico usa taxa de 1 minuto; a curva sobe e desce gradualmente.

## Energia

Energia dinâmica ESTIMADA por regressão local do Kepler legado. Atividade de CPU/eBPF é real; os coeficientes oficiais não foram calibrados para esta VM. A parcela ociosa do host não é incluída. O gráfico de potência usa W e o de energia usa J no intervalo selecionado.

O instalador usa sensores quando disponíveis; sem sensores, ativa regressão local com os modelos oficiais do Kepler legado.
Não há medidor fake. Valores de energia estimados são identificados no mesmo dashboard CPU Energy Lab.
Potência atribuída a um pod é uma atribuição do Kepler a partir do sensor e do uso de CPU;
não é um wattímetro físico por pod. Numa VM, um sensor exposto pode pertencer ao host físico.
CPU stress mede carga de CPU; não é um teste de GPU.

Para parar o experimento de exemplo pelo terminal:
`kubectl -n default delete stresschaos cpu-stress-ubuntu --ignore-not-found`.
