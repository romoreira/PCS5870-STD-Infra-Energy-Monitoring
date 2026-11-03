# CPU Energy Lab — Prometheus, Grafana, Kepler e Chaos Mesh

O `application_install.sh` é autocontido e instala a camada de aplicações sobre o Kubernetes que já está funcionando na VM Ubuntu 22.04 de 8 vCPUs e 16 GB de RAM.

| Componente | Instalação | Função |
|---|---|---|
| Prometheus + Grafana | Helm, kube-prometheus-stack `92.17.0` | Métricas e dashboard `CPU Energy Lab` |
| Kepler | Helm, `0.12.0` | Potência/energia a partir de sensores reais |
| Chaos Mesh | Helm, `2.8.7` | Criar estresse de CPU pelo navegador |
| Ubuntu de teste | Deployment `ubuntu-test`, imagem Ubuntu 22.04 | Alvo isolado no namespace `cpu-lab` |

Os três pacotes Helm têm versões e SHA-256 fixados. Os manifests são renderizados e as imagens são baixadas antes da instalação. As imagens adicionais criadas pelo Prometheus Operator também são incluídas na verificação inicial.

## Executar

Copie o arquivo para `~/testbed-automator/` na VM. Execute como `ubuntu`:

```bash
cd ~/testbed-automator
chmod +x application_install.sh
./application_install.sh --check
./application_install.sh
```

O `--check` consulta cluster e sensores e escreve diagnósticos locais. Ele não instala recursos no cluster. O script requer `kubectl`, Helm 3, Python/PyYAML, `curl`, `openssl`, `crictl`, `systemctl` e sudo, já presentes após a instalação da infraestrutura.

O diretório de saída padrão é `~/testbed-automator/build/applications/`. Para outro diretório, use `APP_BUILD_DIR=/caminho ./application_install.sh`.

A aplicação não executa `kubeadm`, não reconfigura nem reinicia o containerd. Quando o host não possui rota IPv4 para os Services, acrescenta uma rota **somente para o Service CIDR real do cluster**, através da interface local. Essa rota é necessária para chamadas do API server aos admission webhooks do Chaos Mesh e fica persistente em `testbed-service-cidr-route.service`. Não é criada uma rota padrão IPv4 nem escolhido um gateway externo.

## Energia real e limitações da VM

Você escolheu CPU nesta VM e somente métricas reais. Por isso:

- Uso de CPU e memória vêm de métricas reais do kubelet/cAdvisor.
- Kepler usa apenas os medidores `rapl` e `hwmon`. GPU e medidores sintéticos ficam desabilitados.
- Se não houver sensores legíveis, o chart Kepler é instalado, mas seu DaemonSet fica com **zero pods desejados** por seleção de nó. Isso evita um CrashLoopBackOff esperado por falta de sensores.
- Nesse caso, o dashboard continua mostrando CPU/memória e informa que watts/joules estão indisponíveis. Ausência de energia não é mostrada como consumo zero.
- Se houver sensores, o script espera o Kepler iniciar e confirma que o Prometheus o coleta. Candidatos a sensores não garantem que todo hardware seja compatível; erros reais de inicialização são mostrados para diagnóstico.
- Em uma VM, sensores eventualmente expostos podem medir o host físico. A atribuição calculada para um pod não é uma medição elétrica exclusiva daquele pod ou daquela VM.

Logo, é possível observar o aumento de CPU com o experimento. Observar aumento de potência real depende dos sensores. Estresse de CPU não implica aumento do consumo de uma GPU.

No Grafana, selecione **uma única zona** de energia por vez. `package`, `core` e `dram` podem representar domínios sobrepostos. Não some essas zonas. Se um sensor hwmon usar outro nome, escolha a zona correspondente no seletor do dashboard.

## Acesso pelo navegador

Ao final, o instalador gera `build/applications/ACESSO.md` com o endereço da VM e os comandos completos.

O acesso direto usa Services dual-stack com IPv4 primário e IPv6 secundário, preservando o ClusterIP IPv4 já instalado:

| Aplicação | NodePort TCP | URL nesta VM |
|---|---|---|
| Grafana / dashboard | `30000` | http://[2001:48d0:6031:1991:f816:3eff:fee2:e44a]:30000/d/cpu-energy-lab |
| Chaos Dashboard | `30001` | http://[2001:48d0:6031:1991:f816:3eff:fee2:e44a]:30001 |

O computador precisa ter conectividade IPv6. Autorize TCP 30000 e 30001 no grupo de segurança da nuvem e, se ativo, no firewall da VM, limitando a origem ao IPv6/rede do seu computador. O instalador não abre o firewall. O acesso direto usa HTTP; o túnel SSH abaixo transporta as credenciais criptografadas.

Prometheus, Kepler e os exporters continuam como ClusterIP. O instalador verifica conflito das portas antes de aplicar os charts e confirma acesso HTTP pelos NodePorts IPv6 dentro da VM. Esse teste local não verifica o firewall da nuvem nem a conectividade do seu computador.

### Alternativa com túnel SSH

Na VM, mantenha este comando aberto:

```bash
~/testbed-automator/build/applications/application_access.sh
```

No seu computador, abra outro terminal (PowerShell/OpenSSH também funciona):

```bash
ssh -N -L 3000:127.0.0.1:3000 -L 2333:127.0.0.1:2333 -L 9090:127.0.0.1:9090 ubuntu@2001:48d0:6031:1991:f816:3eff:fee2:e44a
```

Use as mesmas opções de chave e bastion que você já utiliza. Mantenha ambos os terminais abertos. Navegue para Grafana `http://localhost:3000/d/cpu-energy-lab`, Chaos `http://localhost:2333` e Prometheus `http://localhost:9090`. Os port-forwards escutam somente em `127.0.0.1`.

## Login

Grafana: usuário `admin`. Leia a senha na VM:

```bash
cat ~/testbed-automator/build/applications/credentials/grafana-password.txt
```

Chaos Dashboard: use o token gerado na VM:

```bash
cat ~/testbed-automator/build/applications/credentials/chaos-token.txt
```

O token solicita validade de 24 horas, sujeita ao limite do API server. Para renovar:

```bash
~/testbed-automator/build/applications/renew_chaos_token.sh
```

O usuário do dashboard gerencia experimentos apenas em `cpu-lab`; pode ler namespaces para preencher os seletores da interface. O controlador do Chaos Mesh também é configurado para o namespace alvo `cpu-lab`, com filtragem de namespace habilitada.

## Aplicar estresse pelo navegador

1. Abra Grafana e Chaos Dashboard em abas separadas.
2. No Grafana, abra `CPU Energy Lab`; observe aproximadamente 1 minuto de baseline.
3. No Chaos Dashboard, escolha **NEW EXPERIMENT → STRESS TEST → CPU**.
4. Preencha:

| Campo | Valor |
|---|---|
| Nome | `cpu-stress-ubuntu` |
| Namespace | `cpu-lab` |
| Seletor | label `app=ubuntu-test` |
| Container | `ubuntu-test` |
| Mode | `one` |
| CPU workers | `3` |
| Load | `80` |
| Duração | `120s` |

5. Submeta o experimento e acompanhe o estado no Chaos Dashboard.
6. No Grafana, compare o uso de CPU antes, durante e depois. O painel usa uma taxa de 1 minuto, então a resposta é suavizada.

O Ubuntu de teste tem limite de 4 CPUs e 1 GiB de memória. Três workers a 80% visam aproximadamente 2,4 núcleos de carga, sujeitos ao escalonamento. O limite reserva capacidade para os componentes do cluster.

O instalador **não inicia estresse automaticamente**. Ele usa `--dry-run=server` para validar o experimento e o webhook. A cópia YAML fica em `build/applications/cpu-stress.yaml`.

Para o mesmo teste por terminal, quando você decidir iniciá-lo:

```bash
kubectl apply -f ~/testbed-automator/build/applications/cpu-stress.yaml
```

Para interromper o experimento de exemplo:

```bash
kubectl -n cpu-lab delete stresschaos cpu-stress-ubuntu --ignore-not-found
```

## Reexecução e persistência

O script reaproveita os releases Helm das mesmas versões e preserva a senha do Grafana. Prometheus recebe PVC de 5 GiB, Grafana de 1 GiB e Chaos Dashboard de 1 GiB, todos em `openebs-hostpath`. O Prometheus mantém até 2 dias / aproximadamente 3 GB de dados, sujeito à coleta e compactação.

Esta revisão também corrige documentos vazios que viravam `--- null` no pós-processamento do chart Chaos Mesh e impediam sua instalação. Pode substituir o script anterior e reexecutar para continuar a instalação interrompida, preservando os volumes e a senha do Grafana.

A reexecução reaplica os recursos gerenciados, pode atualizar/reiniciar os pods das aplicações e renova o token do dashboard. Namespaces existentes sem o marcador do instalador e releases de outras versões são recusados. Experimentos StressChaos existentes em `cpu-lab` precisam ser encerrados/removidos antes de reexecutar.

Não há remoção automática de volumes ou reset do cluster em caso de falha. Os manifests, valores Helm, hashes e logs ficam em `build/applications/`. Credenciais têm permissões restritas; não as inclua ao compartilhar logs.

## Validação do pacote

Foram verificados Bash, ShellCheck, os charts fixados renderizados para Kubernetes 1.35.10, o schema StressChaos, os valores de persistência e os cenários com/sem sensores. Os testes locais não equivalem a executar esses charts na VM. O próprio instalador verifica a saúde das aplicações, o admission webhook e a existência de métricas reais de CPU no Prometheus.

## Referências

- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Kepler: instalação](https://sustainable-computing.io/kepler/installation/guide/)
- [Kepler: configuração e medidores](https://sustainable-computing.io/kepler/usage/configuration/)
- [Kepler: métricas e zonas](https://sustainable-computing.io/kepler/design/metrics/)
- [Chaos Mesh: Helm](https://chaos-mesh.org/docs/production-installation-using-helm/)
- [Chaos Mesh: estresse por CPU](https://chaos-mesh.org/docs/simulate-heavy-stress-on-kubernetes/)
- [Chaos Mesh: permissões](https://chaos-mesh.org/docs/manage-user-permissions/)

- [Kubernetes: Services dual-stack](https://kubernetes.io/docs/concepts/services-networking/dual-stack/)
