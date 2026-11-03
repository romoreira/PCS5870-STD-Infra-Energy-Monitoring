# 🌱 PCS5870 — Sustentabilidade e Tecnologias Digitais

## Laboratório de infraestrutura e monitoramento de energia

**Escola Politécnica da Universidade de São Paulo — Poli-USP**  
**Professor responsável pela atividade:** Prof. Rodrigo Moreira  
**Supervisão:** Profa. Tereza Cristina Melo de Brito Carvalho  
**Projeto:** `PCS5870-STD-Infra-Energy-Monitoring`

Este roteiro apresenta a montagem de um ambiente Kubernetes em uma máquina virtual Ubuntu, a instalação das aplicações de observabilidade e a execução de experimentos de carga de CPU. O objetivo é relacionar o uso de recursos de um pod com sua potência e energia estimadas.

> 🎓 **Organização da atividade:** inicialmente, acompanhe a demonstração orientada pelo professor. O endereço e o acesso ao repositório serão liberados posteriormente para reprodução, estudo e conferência dos scripts. Os comandos de clonagem deste roteiro devem ser executados após essa liberação. Se o professor já disponibilizou os arquivos na VM durante a aula, avance diretamente para a pasta do projeto indicada por ele.

---

## 🎯 1. O que será construído

| Componente | Papel no laboratório |
|---|---|
| VM Ubuntu 22.04 | Hospeda o ambiente experimental |
| Kubernetes e containerd | Executam e gerenciam os containers |
| Flannel, Multus e OVS CNI | Configuram a conectividade dos pods |
| OpenEBS LocalPV Hostpath | Fornece armazenamento persistente local |
| Prometheus | Coleta e armazena as métricas |
| Grafana | Apresenta o dashboard **CPU Energy Lab** |
| Kepler | Atribui ou estima potência e energia dos workloads |
| Chaos Mesh | Injeta carga controlada de CPU |
| Ubuntu de teste | Pod alvo, criado no namespace **`default`** |

Ao final, o estudante acessará o Grafana em **http://127.0.0.1:3000** e o Chaos Mesh em **http://127.0.0.1:2333**, por um túnel SSH.

## 🧰 2. Preparar a VM e os dados de acesso

O professor criará ou disponibilizará uma VM com a seguinte configuração de referência:

| Item | Configuração |
|---|---|
| Sistema operacional | Ubuntu Server **22.04**, arquitetura **amd64** |
| Processamento | **8 vCPUs** |
| Memória | **16 GB de RAM** |
| Rede | IPv6 global para acesso e IPv4 interno atribuído à interface da VM |
| Usuário de acesso | `ubuntu`, com permissão de `sudo` |
| Saída para a Internet | Necessária para baixar pacotes, charts e imagens |

O IPv6 é atribuído pela infraestrutura que hospeda a VM. Para esta atividade, o estudante recebe do professor os endereços e a string de acesso; não precisa configurar manualmente um novo IPv6 no sistema operacional.

### 📝 Ficha da sua VM

Preencha os campos com os dados fornecidos para **a sua máquina**:

| Informação | Preenchimento |
|---|---|
| Nome da VM | `____________________________` |
| IPv6 global | `____________________________` |
| IPv4 interno | `____________________________` |
| Usuário SSH | `ubuntu` ou o usuário informado pelo professor |
| Arquivo de configuração SSH | `ssh_config` |
| Chave de acesso | `slice_key` |
| String SSH fornecida | `____________________________` |

> 🔄 **Uma VM nova pode receber outros IPs.** Atualize a ficha e os comandos de acesso sempre que recriar a máquina. Os instaladores detectam os endereços atribuídos à interface; o túnel SSH deve apontar para os endereços atuais.

Os arquivos `ssh_config` e `slice_key` devem permanecer no computador utilizado para o acesso. A chave privada e as credenciais geradas pelo laboratório não devem ser incluídas no repositório ou nos registros compartilhados da atividade.

## 💻 3. Entender onde executar cada comando

| Local | Como reconhecer | Uso |
|---|---|---|
| **Computador local — PowerShell** | Prompt começando com `PS C:\...>` | Abrir SSH e o túnel para as interfaces web |
| **VM — terminal Ubuntu** | Prompt semelhante a `ubuntu@vm1:~$` | Clonar o projeto, instalar o cluster e as aplicações |
| **Navegador do computador local** | Abas do Grafana e Chaos Mesh | Consultar métricas e criar experimentos |

Copie somente os comandos dos blocos, sem copiar o texto do prompt.

## 🔑 4. Entrar na VM

**📍 Execute no computador local, em um PowerShell.**

Entre na pasta que contém os arquivos de acesso. Ajuste o caminho e o IPv6:

```powershell
cd "C:\caminho\para\keys"

$VM_IPV6 = "IPV6_FORNECIDO_PELO_PROFESSOR"

ssh -F .\ssh_config -i .\slice_key "ubuntu@${VM_IPV6}"
```

Se o professor forneceu outra string SSH, preserve as opções de configuração, chave e bastion dessa string. Confirme a identidade do servidor na primeira conexão de acordo com as informações fornecidas para a VM.

Após conectar, os próximos comandos serão executados **dentro do Ubuntu**.

## 📦 5. Obter o projeto

**📍 Execute na VM, após a liberação do repositório.**

Prepare as ferramentas básicas:

```bash
sudo apt-get update
sudo apt-get install -y git curl python3
```

Substitua o valor de `REPO_URL` pela URL liberada pelo professor:

```bash
cd ~

REPO_URL="URL_DO_REPOSITORIO_LIBERADA_PELO_PROFESSOR"

git clone "$REPO_URL" PCS5870-STD-Infra-Energy-Monitoring
cd ~/PCS5870-STD-Infra-Energy-Monitoring
```

A organização utilizada neste roteiro é:

| Caminho no projeto | Conteúdo |
|---|---|
| `install.sh` | Instalador da infraestrutura Kubernetes |
| `kubeadm-config.yaml` | Configuração utilizada pelo instalador do cluster |
| `application_cpu_energy_lab/application_install.sh` | Instalador integrado das aplicações |
| `application_cpu_energy_lab/APPLICATION_README.md` | Detalhes das aplicações e dos diagnósticos |
| Pastas `build` | Arquivos gerados durante a execução em cada ambiente |

Nesta atividade, “construir o testbed” significa executar a automação que prepara o host, instala e configura o cluster. As aplicações são implantadas a partir de charts e imagens fixados pelos instaladores; não é necessário compilar os projetos manualmente.

## 🏗️ 6. Construir o testbed Kubernetes

**📍 Execute na VM, na raiz do projeto.**

Primeiro, confira a interface e os endereços:

```bash
ip -br address
ip -6 route show default
```

Registre o IPv4 interno e o IPv6 global da interface de acesso. O nome utilizado no ambiente de referência é `enp3s0`; se sua VM utilizar outro nome, ajuste a variável abaixo.

```bash
cd ~/PCS5870-STD-Infra-Energy-Monitoring
chmod +x install.sh

INTERFACE="enp3s0"

NODE_INTERFACE="$INTERFACE" ./install.sh --check
```

O `--check` verifica o host e os endereços de download. Se concluir sem erro, execute a instalação:

```bash
NODE_INTERFACE="$INTERFACE" ./install.sh
```

Execute o script como usuário `ubuntu`, sem acrescentar `sudo` antes de `./install.sh`. O próprio instalador solicita os privilégios necessários. Se a VM exigir uma senha de `sudo` que não foi fornecida, confirme a configuração de acesso com o professor.

Aguarde o término dos downloads, da criação do cluster e dos testes funcionais. O tempo varia conforme a rede e as imagens disponíveis. Não inicie o instalador das aplicações enquanto esta etapa estiver em execução.

### ✅ Conferir a infraestrutura

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get storageclass
```

Verifique:

- o nó aparece como **`Ready`**;
- os pods dos componentes do cluster estão prontos;
- Flannel, Multus e OVS CNI estão funcionando;
- o provisionador OpenEBS está em execução e existe a StorageClass `openebs-hostpath`;
- o instalador encerrou com a mensagem **`Installation and functional smoke checks completed successfully.`**

O script realiza verificações de rede, DNS, acesso IPv6 e armazenamento. O diretório `build` na raiz do projeto guarda os arquivos gerados pela infraestrutura.

## 📊 7. Instalar as aplicações

**📍 Execute na VM, na pasta das aplicações.**

```bash
cd ~/PCS5870-STD-Infra-Energy-Monitoring/application_cpu_energy_lab
chmod +x application_install.sh
```

### 🔄 Começar com o estado da VM atual

Em uma VM recém-criada, a pasta `build` das aplicações não deve reutilizar o estado de uma VM anterior. Se ela veio junto com os arquivos copiados ou clonados, preserve-a com outro nome antes da primeira instalação nesta máquina:

```bash
if [ -d build ]; then
  mv build "build-anterior-$(date +%Y%m%d-%H%M%S)"
fi
```

Esses comandos são executados **dentro de `application_cpu_energy_lab`**. A preservação da pasta é para o início em uma VM nova; em reexecuções na mesma VM, mantenha o estado gerado pela instalação atual.

Agora valide e instale:

```bash
./application_install.sh --check
./application_install.sh
```

O instalador integrado prepara Prometheus, Grafana, Chaos Mesh, Kepler e a Deployment `ubuntu-test`. Não é necessário executar um segundo instalador de energia.

Quando não encontra sensores de energia legíveis na VM, ele integra o estimador local do Kepler legado e identifica os resultados como **estimados** no mesmo dashboard **CPU Energy Lab**.

### ✅ Conferir as aplicações

```bash
kubectl get pods -A
kubectl -n default get pods -l app=ubuntu-test -o wide
helm list -A
```

| Namespace | Recursos esperados |
|---|---|
| `default` | Pod `ubuntu-test-...`, alvo dos experimentos |
| `monitoring` | Grafana, Prometheus e componentes de coleta |
| `chaos-mesh` | Dashboard, controlador e daemon do Chaos Mesh |
| `kepler-estimated` | Exporter de estimativas, quando a VM não possui sensores disponíveis |
| `kepler` | Release para coleta por sensores; pode ficar sem pods em nós sem sensores |

Só avance quando a instalação concluir com sucesso. O diretório `application_cpu_energy_lab/build/applications` contém logs, configurações, instruções de acesso e credenciais da instalação atual.

## 🌐 8. Abrir o túnel SSH

**📍 Execute em um novo PowerShell no computador local.**

Mantenha a sessão Ubuntu disponível para consultar comandos e credenciais. No novo PowerShell, abra a pasta das chaves e preencha **os dois IPs atuais** da ficha da VM:

```powershell
cd "C:\caminho\para\keys"

$VM_IPV6 = "IPV6_ATUAL_DA_VM"
$VM_IPV4 = "IPV4_INTERNO_ATUAL_DA_VM"

ssh -F .\ssh_config -i .\slice_key -N -o ExitOnForwardFailure=yes -L "3000:${VM_IPV4}:30000" -L "2333:${VM_IPV4}:30001" "ubuntu@${VM_IPV6}"
```

As variáveis precisam ser definidas neste novo terminal; variáveis de outro PowerShell não são automaticamente compartilhadas.

| Trecho | Função |
|---|---|
| `-F .\ssh_config` | Usa a configuração de acesso fornecida |
| `-i .\slice_key` | Seleciona a chave SSH |
| `ubuntu@IPv6` | Identifica o usuário e o destino da conexão SSH |
| `-L 3000:IPv4:30000` | Encaminha a porta local 3000 para o NodePort do Grafana |
| `-L 2333:IPv4:30001` | Encaminha a porta local 2333 para o NodePort do Chaos Dashboard |
| `-N` | Mantém o túnel sem abrir um shell remoto |

> 📌 **Mantenha esse terminal aberto.** É normal não aparecer um prompt Ubuntu com `-N`. Ao encerrar o comando com `Ctrl+C` ou fechar o terminal, o túnel é encerrado. O túnel usa o SSH; o acesso direto aos NodePorts pela Internet não é necessário para esta atividade.

O IPv6 permite chegar à VM; o IPv4 interno é o destino dos encaminhamentos visto a partir da própria VM. Uma máquina recriada pode exigir a atualização de ambos no comando.

<details>
<summary>🧪 Exemplo da VM utilizada na demonstração do professor</summary>

O exemplo abaixo funcionou no ambiente de referência. Os IPs são específicos dessa VM e devem ser substituídos quando a máquina mudar.

```powershell
ssh -F ssh_config -i slice_key -N -o ExitOnForwardFailure=yes -L 3000:10.30.6.79:30000 -L 2333:10.30.6.79:30001 ubuntu@2001:48d0:6031:1991:f816:3eff:fecd:5bec
```

</details>

## 🔓 9. Acessar Grafana e Chaos Mesh

**📍 Abra o navegador no computador em que o túnel está em execução.**

| Interface | Endereço |
|---|---|
| Grafana | [http://127.0.0.1:3000](http://127.0.0.1:3000) |
| Dashboard CPU Energy Lab | [http://127.0.0.1:3000/d/cpu-energy-lab](http://127.0.0.1:3000/d/cpu-energy-lab) |
| Chaos Mesh | [http://127.0.0.1:2333](http://127.0.0.1:2333) |

### 🔐 Consultar as credenciais

Ao concluir a instalação, o script mostra os dados de login. Para consultá-los novamente, execute **na VM**:

```bash
cd ~/PCS5870-STD-Infra-Energy-Monitoring/application_cpu_energy_lab
./application_install.sh --credentials
```

No Grafana, utilize o usuário e a senha exibidos. O usuário inicial é `admin`. Um prompt como `ubuntu@vm1:~$` não faz parte da senha.

No Chaos Mesh, preencha:

| Campo da janela de login | Valor |
|---|---|
| **Name** | `default-manager` |
| **Token** | A linha inteira do token exibido pelo comando |

Clique em **Submit**. O nome é o identificador desse login na interface. O token permite gerenciar os experimentos no namespace `default`.

Se precisar renovar o token:

```bash
./application_install.sh --renew-chaos-token
```

Cadastre o novo token na interface quando o anterior expirar. Esses comandos não reinstalam as aplicações.

## 🧪 10. Executar o primeiro experimento pelo navegador

Abra o **CPU Energy Lab** e o **Chaos Dashboard** em abas separadas.

### 10.1 Observar o estado inicial

No Grafana, escolha um intervalo recente, como **Last 15 minutes**, e mantenha a atualização automática em **5s**. Observe aproximadamente um minuto sem carga injetada e registre o nível inicial de CPU e potência estimada.

### 10.2 Criar um teste leve

No Chaos Mesh, crie um novo experimento do tipo **Stress Test → CPU**. Dependendo da apresentação da interface, o recurso aparece como **StressChaos**.

| Campo | Primeiro teste |
|---|---|
| Nome | `cpu-stress-01` |
| Namespace do experimento | **`default`** |
| Namespace do alvo | **`default`** |
| Label selector | `app=ubuntu-test` |
| Container | `ubuntu-test` |
| Mode | `one` |
| CPU workers | **`1`** |
| CPU load | **`50`** |
| Duration | **`30s`** |

Revise os valores e submeta o experimento. Confirme na interface o pod selecionado e os eventos de aplicação da carga.

### 10.3 Acompanhar início e recuperação

No Grafana, observe a CPU e a potência durante a carga e após o término. As curvas utilizam médias de uma janela de 1 minuto, por isso não mudam instantaneamente. Aguarde a queda da carga e confirme a recuperação antes de iniciar outro teste.

**Um worker a 50% visa aproximadamente 0,5 núcleo**, sujeito ao escalonamento. Isso não significa 50% de uma VM inteira com 8 vCPUs. Como o teste dura 30s e a taxa do gráfico utiliza 1 minuto, o pico exibido pode ser atenuado pela média. O container Ubuntu tem limite de 4 CPUs; aumentar o número de workers pode saturar esse limite.

Depois de confirmar o ciclo completo, aumente a carga gradualmente conforme a orientação do professor. Utilize um nome diferente para cada execução e evite experimentos simultâneos no mesmo pod ao realizar comparações.

O arquivo `CPU_STRESS.yaml` e a cópia gerada em `build/applications/cpu-stress.yaml` contêm um exemplo mais intenso, com 3 workers, carga de 80% e duração de 120s. O primeiro teste deste roteiro é deliberadamente menor.

## ⚡ 11. Interpretar os resultados

| Indicador | Interpretação |
|---|---|
| CPU do Ubuntu, em núcleos | Uso de CPU atribuído ao container/pod de teste |
| CPU da VM, em % | Uso global, incluindo Kubernetes, observabilidade e outras tarefas |
| Potência dinâmica estimada, em **W** | Estimativa da taxa de consumo atribuída ao trabalho do pod |
| Energia dinâmica estimada, em **J** | Energia atribuída ao pod no intervalo selecionado |
| Energia dinâmica estimada, em **Wh** | A mesma energia convertida: `Wh = J / 3600` |

**CPU e potência devem diminuir quando a carga termina. Energia é acumulada no intervalo:** um card de J/Wh não precisa voltar imediatamente a zero ao encerrar o estresse. Em uma janela móvel, o valor também muda conforme o trecho de carga entra ou sai do intervalo.

> 📐 **Limite de interpretação:** nesta VM sem sensores de energia, o Kepler utiliza modelos oficiais pré-treinados e atividade real coletada do sistema. Os coeficientes não foram calibrados para o host físico desta VM. Os resultados representam estimativas de energia dinâmica atribuída ao pod, sem a parcela ociosa do host, e não uma leitura elétrica calibrada da VM inteira.

Para comparar execuções, mantenha a mesma configuração da VM e selecione períodos de igual duração. Registre os horários de início e fim, os parâmetros do experimento, o uso de CPU, a potência e a energia observadas.

## 🩺 12. Diagnosticar problemas

### A aplicação não instala e informa que o diretório pertence a outro cluster

Mensagem:

```text
This build directory belongs to another cluster
```

A pasta `build` das aplicações contém o identificador de outro cluster. Em uma VM nova, preserve essa pasta conforme a etapa 7 e execute o instalador novamente. Esse erro não exige recriar o Kubernetes.

### A conexão SSH não chega à VM

Confira o IPv6 atual, o usuário, a chave e a utilização de `ssh_config`, que pode conter a configuração do bastion. No PowerShell, obtenha detalhes da conexão:

```powershell
ssh -vv -F .\ssh_config -i .\slice_key "ubuntu@${VM_IPV6}"
```

Se a VM foi recriada, utilize os novos dados fornecidos pelo professor. Uma configuração para outra máquina ou outro usuário não substitui os dados da VM atual.

### Grafana ou Chaos Mesh não abrem no navegador

Confirme que o túnel continua aberto e que o navegador está no mesmo computador. Na VM, verifique:

```bash
kubectl -n monitoring get service grafana
kubectl -n chaos-mesh get service chaos-dashboard
kubectl get pods -A
```

As portas esperadas são 30000 para Grafana e 30001 para Chaos Dashboard. Se o PowerShell indicar que a porta local está ocupada, encerre o túnel antigo que você abriu antes de iniciar outro.

### O tempo terminou, mas a CPU continua alta

Primeiro, clique em **Pause** no experimento. Na VM, observe o alvo enquanto a carga ainda estiver alta:

```bash
cd ~/PCS5870-STD-Infra-Energy-Monitoring/application_cpu_energy_lab
./application_install.sh --diagnose-cpu
kubectl -n default describe stresschaos cpu-stress-01
```

O diagnóstico compara o contador nativo de CPU do container com o Prometheus e registra os processos de estresse. O estado da interface, sozinho, não substitui essa verificação.

Para solicitar a recuperação removendo somente o experimento deste exemplo:

```bash
kubectl -n default delete stresschaos cpu-stress-01
```

Se o teste tiver outro nome, substitua `cpu-stress-01`. Aguarde a queda da CPU; se ela não ocorrer, preserve o diagnóstico e consulte o professor antes de executar outra carga.

### Fazer um teste controlado de injeção e monitoramento

Sem outro StressChaos ativo no namespace `default`, execute:

```bash
./application_install.sh --test-cpu
```

Esse modo **inicia carga de CPU**: um controle direto de 20s e um experimento Chaos configurado para 60s. Ele verifica o cgroup do Ubuntu e a leitura do Prometheus. O comando normal de instalação e o modo `--diagnose-cpu` não iniciam estresse.

### Os painéis de energia estão indisponíveis

Na VM sem sensores, confira o exporter e seu log:

```bash
kubectl -n kepler-estimated get pods
kubectl -n kepler-estimated logs daemonset/kepler-estimated --tail=100
```

O Kepler 0.12 no namespace `kepler` pode ficar sem pods nesse cenário; o exporter de estimativas está em `kepler-estimated`. O painel deve identificar explicitamente a energia como estimada. Não interprete ausência de métricas como consumo zero.

## 📚 13. Registro e estudo posterior

Para organizar a análise, registre:

- identificação e configuração da VM;
- parâmetros e horários de cada experimento;
- captura do dashboard antes, durante e após a carga;
- valores de CPU, potência e energia em intervalos comparáveis;
- dificuldades encontradas e diagnósticos utilizados;
- diferença entre uso medido de CPU e estimativa de energia.

Quando o repositório for liberado, utilize os scripts para conferir como a infraestrutura, os charts, o alvo no namespace `default` e as consultas do dashboard foram configurados. Os dados de acesso da ficha da VM devem ser tratados separadamente dos arquivos compartilhados da atividade.

### Referências para consulta

- [Kubernetes — documentação](https://kubernetes.io/docs/)
- [Prometheus — funções de consulta](https://prometheus.io/docs/prometheus/latest/querying/functions/)
- [Grafana — documentação](https://grafana.com/docs/grafana/latest/)
- [Chaos Mesh — executar experimentos](https://chaos-mesh.org/docs/run-a-chaos-experiment/)
- [Chaos Mesh — experimentos de estresse](https://chaos-mesh.org/docs/simulate-heavy-stress-on-kubernetes/)
- [Kepler — estimativa de potência na arquitetura legada](https://sustainable-computing.io/archive/kepler_model_server/power_estimation/)
- [Kepler — compatibilidade do Model Server](https://sustainable-computing.io/model-server-compatibility/)

---

**🌱 PCS5870 — Sustentabilidade e Tecnologias Digitais · Escola Politécnica da USP**  
**Atividade conduzida pelo Prof. Rodrigo Moreira · Supervisão: Profa. Tereza Cristina Melo de Brito Carvalho**
