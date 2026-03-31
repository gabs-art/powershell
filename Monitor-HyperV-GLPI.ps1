#Requires -Version 5.1
<#
.SYNOPSIS
    Monitora VMs do Hyper-V e abre chamados automaticos no GLPI quando
    qualquer VM estiver em estado diferente de Running.
    Apenas monitora e informa -- nao altera o estado das VMs.

.DESCRIPTION
    Script desenvolvido para ambientes gerenciados pela TRUSTIT.
    Verifica todas as VMs do host Hyper-V local, tenta religar automaticamente
    e abre chamado no GLPI caso a VM nao volte ao estado Running.

    Integracao GLPI conforme Referencia-Integracao-GLPI.docx:
    - Endpoint: /apirest.php
    - Autenticacao: Basic Auth
    - HTTP client: curl.exe (Invoke-RestMethod falha por TLS no PS 5.x)
    - JSON: arquivo temporario sem BOM

.PARAMETER VMs
    Nomes especificos de VMs a monitorar. Se omitido, monitora TODAS as VMs do host.

.EXAMPLE
    # Monitorar todas as VMs
    .\Monitor-HyperV-GLPI.ps1

.EXAMPLE
    # Monitorar VMs especificas
    .\Monitor-HyperV-GLPI.ps1 -VMs "SRV-DC01","SRV-FILES","SRV-SQL"

.EXAMPLE
    # Uso na Scheduled Task (campo Argumentos):
    -NonInteractive -ExecutionPolicy Bypass -File "C:\TRUSTIT\Monitor-HyperV-GLPI.ps1"

.NOTES
    Versao : 1.0
    Autor  : TRUSTIT - Confianca e Tecnologia Ltda
    Uso    : Agende via Task Scheduler a cada 5 minutos no HOST Hyper-V
    Req.   : Modulo Hyper-V instalado + permissao de administrador Hyper-V
#>

param(
    [Parameter(Mandatory = $false)]
    [string[]]$VMs
)

# ============================================================
#  CONFIGURACOES GLPI
# ============================================================

$GLPI_URL       = "https://suporte.confiancaetecnologia.com.br/apirest.php"
$GLPI_APP_TOKEN = "DsGaJAyh8U9GnUdiMSKVH9s42GZeiiHk5GmIBz4y"
$GLPI_USER      = "script.integration"
$GLPI_PASSWORD  = "Corolla!@#05042019"

# ============================================================
#  IDENTIFICACAO DO CLIENTE - ALTERE AQUI A CADA INSTALACAO
# ============================================================
# Informe o ID da entidade do cliente no GLPI.
# Consulte a tabela de entidades no final deste script.
# Exemplo: TrustIT > PM - Capitolio = ID 5
$GLPI_ENTITY_ID = 11   # <-- ALTERE PARA O ID DA ENTIDADE DO CLIENTE

# Prioridade do chamado
# 1=Muito baixa  2=Baixa  3=Media  4=Alta  5=Muito alta
$GLPI_URGENCY  = 4
$GLPI_PRIORITY = 4
$GLPI_TYPE         = 1    # 1=Incidente  2=Requisicao
$GLPI_CATEGORY_ID  = 56   # Categoria Hyper-V
$GLPI_REQUESTER_ID = 1491 # script.integration


# Pastas de trabalho
$WORK_DIR  = "C:\TRUSTIT"
$LOG_DIR   = "$WORK_DIR\Logs"
$DEDUP_DIR = "$WORK_DIR\Dedup"
$TEMP_JSON = "$WORK_DIR\glpi_hyperv_temp.json"
$LOG_FILE  = "$LOG_DIR\Monitor-HyperV.log"
$HOSTNAME  = $env:COMPUTERNAME

# Estados que devem disparar alerta
# Running = OK | qualquer outro = problema
$ESTADOS_PROBLEMA = @("Off", "Saved", "Paused", "Starting", "Stopping", "Saving", "Pausing", "Resuming", "FastSaved", "FastSaving", "Unknown")

# ============================================================
#  FUNCOES AUXILIARES
# ============================================================

function Ensure-Dirs {
    foreach ($d in @($WORK_DIR, $LOG_DIR, $DEDUP_DIR)) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
}

function Rotate-Log {
    if ((Test-Path $LOG_FILE) -and (Get-Item $LOG_FILE).Length -gt 10MB) {
        $lines = Get-Content $LOG_FILE | Select-Object -Skip 1000
        $lines | Set-Content $LOG_FILE -Encoding UTF8
        Write-Log "Log rotacionado."
    }
}

function Get-DedupFile([string]$VMName) {
    $nome = $VMName -replace '[\\/:*?"<>|]', '_'
    return Join-Path $DEDUP_DIR "hyperv_ticket_$nome.lock"
}

function Chamado-JaAberto([string]$VMName) {
    return Test-Path (Get-DedupFile $VMName)
}

function Marcar-ChamadoAberto([string]$VMName, [string]$TicketId) {
    $TicketId | Set-Content -Path (Get-DedupFile $VMName) -Encoding UTF8
}

function Limpar-ChamadoAberto([string]$VMName) {
    $f = Get-DedupFile $VMName
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ============================================================
#  INTEGRACAO GLPI
# ============================================================

function Get-BasicAuth {
    return [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${GLPI_USER}:${GLPI_PASSWORD}")
    )
}

function Obter-SessionToken {
    param([string]$BasicAuth)
    try {
        $raw = & curl.exe -s -k -X GET "$GLPI_URL/initSession" `
            -H "Content-Type: application/json" `
            -H "Accept: application/json" `
            -H "Authorization: Basic $BasicAuth" `
            -H "App-Token: $GLPI_APP_TOKEN"

        $data = $raw | ConvertFrom-Json
        if ($data.session_token) { return $data.session_token }
        Write-Log "session_token nao retornado. Resposta: $raw" "ERROR"
        return $null
    }
    catch {
        Write-Log "Excecao ao obter session_token: $_" "ERROR"
        return $null
    }
}

 

function Set-EntidadeAtiva {
    param([string]$SessionToken)
    # Troca a entidade ativa da sessao para garantir que o chamado
    # seja aberto na entidade correta (GLPI ignora entities_id no payload
    # se a sessao estiver na entidade raiz)
    $json = "{""entities_id"":$GLPI_ENTITY_ID,""is_recursive"":false}"
    [System.IO.File]::WriteAllText($TEMP_JSON, $json, [System.Text.Encoding]::ASCII)
    try {
        $raw = & curl.exe -s -k -X POST "$GLPI_URL/changeActiveEntities" `
            -H "Content-Type: application/json" `
            -H "Accept: application/json" `
            -H "App-Token: $GLPI_APP_TOKEN" `
            -H "Session-Token: $SessionToken" `
            -d "@$TEMP_JSON"
        Write-Log "Entidade ativa alterada para ID $GLPI_ENTITY_ID." "INFO"
    }
    catch {
        Write-Log "Aviso: nao foi possivel alterar entidade ativa: $_" "WARN"
    }
    finally {
        if (Test-Path $TEMP_JSON) { Remove-Item $TEMP_JSON -Force -ErrorAction SilentlyContinue }
    }
}
function Get-GLPIUserId {
    param([string]$BasicAuth, [string]$SessionToken)
    try {
        $raw = & curl.exe -s -k -X GET `
            "$GLPI_URL/User?searchText[name]=$GLPI_USER&range=0-1&forcedisplay[0]=2" `
            -H "Content-Type: application/json" `
            -H "Accept: application/json" `
            -H "App-Token: $GLPI_APP_TOKEN" `
            -H "Session-Token: $SessionToken"

        $data = $raw | ConvertFrom-Json
        if ($data -and $data.Count -gt 0) {
            return $data[0].id
        }
        Write-Log "Nao foi possivel obter ID do usuario '$GLPI_USER' na API GLPI." "WARN"
        return 0
    }
    catch {
        Write-Log "Excecao ao buscar ID do usuario GLPI: $_" "WARN"
        return 0
    }
}
function Encerrar-Sessao([string]$SessionToken) {
    & curl.exe -s -k -X GET "$GLPI_URL/killSession" `
        -H "App-Token: $GLPI_APP_TOKEN" `
        -H "Session-Token: $SessionToken" | Out-Null
}

function Abrir-ChamadoGLPI {
    param(
        [string]$VMName,
        [string]$Estado,
        [string]$Detalhes,
        [string]$SessionToken
    )

    $dataHora = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    $titulo   = "[CRITICO] VM Hyper-V fora do ar: $VMName em $HOSTNAME"

    $conteudo = @"
<table border='0' cellpadding='6' cellspacing='0' style='font-family:Arial,sans-serif;font-size:13px;width:100%'>
  <tr style='background-color:#c0392b;color:#ffffff'>
    <td colspan='2' style='padding:10px 14px;font-size:15px;font-weight:bold'>
      &#9888; VM Hyper-V Fora do Ar - Intervencao Necessaria
    </td>
  </tr>
  <tr style='background-color:#fdf2f2'>
    <td style='width:180px;font-weight:bold;color:#555'>Host Hyper-V</td>
    <td>$HOSTNAME</td>
  </tr>
  <tr>
    <td style='font-weight:bold;color:#555'>Nome da VM</td>
    <td>$VMName</td>
  </tr>
  <tr style='background-color:#fdf2f2'>
    <td style='font-weight:bold;color:#555'>Estado detectado</td>
    <td style='color:#c0392b;font-weight:bold'>$Estado</td>
  </tr>
  <tr>
    <td style='font-weight:bold;color:#555'>Detectado em</td>
    <td>$dataHora</td>
  </tr>
  <tr style='background-color:#fdf2f2'>
    <td style='font-weight:bold;color:#555'>Observacao</td>
    <td>$Detalhes</td>
  </tr>
  <tr>
    <td colspan='2' style='padding-top:10px;color:#555;font-style:italic'>
      A VM foi encontrada em estado diferente de Running pelo monitoramento TRUSTIT.<br>
      Nenhuma acao automatica foi executada. Verifique o host Hyper-V e a VM o mais breve possivel.
    </td>
  </tr>
  <tr style='background-color:#f9f9f9'>
    <td colspan='2' style='padding:8px 14px;font-size:11px;color:#999;border-top:1px solid #ddd'>
      Chamado gerado automaticamente por Monitor-HyperV-GLPI.ps1 - TRUSTIT Confianca e Tecnologia
    </td>
  </tr>
</table>
"@

    $tituloClean   = $titulo   -replace '"', "'" -replace "`n", " " -replace "`r", ""
    $conteudoClean = $conteudo -replace '"', "'" -replace "`r`n", " " -replace "`n", " " -replace "`r", ""

    $json = "{""input"":{""name"":""$tituloClean"",""content"":""$conteudoClean""," +
            """urgency"":$GLPI_URGENCY,""impact"":$GLPI_URGENCY,""priority"":$GLPI_PRIORITY,""type"":$GLPI_TYPE,""entities_id"":$GLPI_ENTITY_ID,""itilcategories_id"":$GLPI_CATEGORY_ID,""_users_id_requester"":$GLPI_REQUESTER_ID}}"

    [System.IO.File]::WriteAllText($TEMP_JSON, $json, [System.Text.Encoding]::ASCII)

    try {
        $raw = & curl.exe -s -k -X POST "$GLPI_URL/Ticket" `
            -H "Content-Type: application/json" `
            -H "Accept: application/json" `
            -H "App-Token: $GLPI_APP_TOKEN" `
            -H "Session-Token: $SessionToken" `
            -d "@$TEMP_JSON"

        $data = $raw | ConvertFrom-Json
        if ($data.id) {
            Write-Log "Chamado aberto. ID: $($data.id) | VM: $VMName | Estado: $Estado" "INFO"
            return "$($data.id)"
        }
        Write-Log "Falha ao abrir chamado. Resposta: $raw" "ERROR"
        return ""
    }
    catch {
        Write-Log "Excecao ao abrir chamado: $_" "ERROR"
        return ""
    }
    finally {
        if (Test-Path $TEMP_JSON) { Remove-Item $TEMP_JSON -Force -ErrorAction SilentlyContinue }
    }
}

# ============================================================
#  LOGICA PRINCIPAL
# ============================================================

Ensure-Dirs
Rotate-Log
Write-Log "=== Inicio da execucao | Host Hyper-V: $HOSTNAME ==="

# Verifica se o modulo Hyper-V esta disponivel
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    Write-Log "Modulo Hyper-V nao encontrado. Execute este script no host Hyper-V." "ERROR"
    exit 1
}

# Obtem a lista de VMs
try {
    if ($VMs -and $VMs.Count -gt 0) {
        $listaVMs = Get-VM -Name $VMs -ErrorAction Stop
        Write-Log "Monitorando VMs especificas ($($listaVMs.Count)): $($listaVMs.Name -join ', ')"
    }
    else {
        $listaVMs = Get-VM -ErrorAction Stop
        Write-Log "Monitorando todas as VMs do host ($($listaVMs.Count)): $($listaVMs.Name -join ', ')"
    }
}
catch {
    Write-Log "Erro ao listar VMs: $_" "ERROR"
    exit 1
}

if ($listaVMs.Count -eq 0) {
    Write-Log "Nenhuma VM encontrada neste host." "WARN"
    exit 0
}

$sessionToken   = $null
$sessaoIniciada = $false

foreach ($vm in $listaVMs) {

    $nome   = $vm.Name
    $estado = $vm.State.ToString()

    Write-Log "Verificando VM: '$nome' | Estado: $estado"

    # VM esta Running - tudo bem
    if ($estado -eq "Running") {
        Write-Log "[$nome] Running. OK."
        if (Chamado-JaAberto $nome) {
            Write-Log "[$nome] VM voltou ao estado Running. Removendo marcador de chamado." "INFO"
            Limpar-ChamadoAberto $nome
        }
        continue
    }

    # VM em estado diferente de Running - apenas registra e abre chamado, sem alterar estado
    Write-Log "[$nome] ALERTA: Estado '$estado' detectado!" "WARN"

    # Verifica anti-duplicidade (nao abre novo chamado se ja houver um aberto)
    if (Chamado-JaAberto $nome) {
        $ticketExistente = Get-Content (Get-DedupFile $nome) -ErrorAction SilentlyContinue
        Write-Log "[$nome] Chamado #$ticketExistente ja aberto. Nao abrira duplicata." "WARN"
        continue
    }

    # Inicia sessao GLPI (uma unica vez por execucao)
    if (-not $sessaoIniciada) {
        Write-Log "Iniciando sessao na API GLPI..."
        $basicAuth    = Get-BasicAuth
        $sessionToken = Obter-SessionToken -BasicAuth $basicAuth
        if (-not $sessionToken) {
            Write-Log "Falha na autenticacao GLPI. Encerrando." "ERROR"
            break
        }
        $sessaoIniciada = $true
        Write-Log "Sessao GLPI iniciada."
        $glpiUserId = Get-GLPIUserId -BasicAuth $basicAuth -SessionToken $sessionToken
        Write-Log "ID do usuario requerente ($GLPI_USER): $glpiUserId"
        Set-EntidadeAtiva -SessionToken $sessionToken
    }

    $detalhes = "VM detectada no estado '$estado'. Nenhuma acao automatica foi executada — intervencao manual necessaria."
    $ticketId = Abrir-ChamadoGLPI -VMName $nome -Estado $estado -Detalhes $detalhes -SessionToken $sessionToken

    if ($ticketId) {
        Marcar-ChamadoAberto -VMName $nome -TicketId $ticketId
    }
}

if ($sessaoIniciada -and $sessionToken) {
    Encerrar-Sessao $sessionToken
    Write-Log "Sessao GLPI encerrada."
}

Write-Log "=== Fim da execucao ==="

# ============================================================
#  TABELA DE ENTIDADES - REFERENCIA PARA INSTALACAO
# ============================================================
# Consulte o GLPI em: Administracao > Entidades para obter os IDs atualizados.
# Preencha $GLPI_ENTITY_ID acima com o ID correspondente ao cliente.
#
# ENTIDADES CADASTRADAS (atualizado em 30/03/2026):
#
#  ID  | ENTIDADE
# -----|------------------------------------------
#  0   | TrustIT (raiz - nao usar para clientes)
#  10  | TrustIT > PM - Pompeu
#  11  | TrustIT > PM - Tocantins
#  12  | TrustIT > PM - Guarapari
#  13  | TrustIT > PM - Barroso
#  15  | TrustIT > PM - Lagoa Dourada
#  16  | TrustIT > CONSORCIO - CIESP
#  19  | TrustIT > PM - Sao Joao Nepomuceno
#  20  | TrustIT > PM - Alegre
#  23  | TrustIT > CONSORCIO - CISUM
#  24  | TrustIT > PM - Lambari
#  25  | TrustIT > PM - Cajuri
#  26  | TrustIT > PM - Sao Sebastiao da Bela Vista
#  28  | TrustIT > PM - Borda da Mata
#  29  | TrustIT > PM - Leopoldina
#
# Para descobrir os IDs rode no PowerShell do servidor:
#
#  $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("script.integration:Corolla!@#05042019"))
#  $session = (& curl.exe -s -k -X GET "https://suporte.confiancaetecnologia.com.br/apirest.php/initSession" `
#      -H "Authorization: Basic $basicAuth" `
#      -H "App-Token: DsGaJAyh8U9GnUdiMSKVH9s42GZeiiHk5GmIBz4y" `
#      -H "Content-Type: application/json" | ConvertFrom-Json).session_token
#  & curl.exe -s -k -X GET "https://suporte.confiancaetecnologia.com.br/apirest.php/Entity?range=0-50" `
#      -H "App-Token: DsGaJAyh8U9GnUdiMSKVH9s42GZeiiHk5GmIBz4y" `
#      -H "Session-Token: $session" `
#      -H "Content-Type: application/json" | ConvertFrom-Json | Select-Object id, completename | Format-Table -AutoSize
# ============================================================
