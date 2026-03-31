#Requires -Version 5.1
<#
.SYNOPSIS
    Monitora servicos Windows e abre chamados automaticos no GLPI via API REST.

.DESCRIPTION
    Script desenvolvido para ambientes gerenciados pela TRUSTIT.
    Monitora uma lista de servicos criticos, tenta reinicia-los automaticamente
    e abre chamado no GLPI caso o reinicio falhe.

    IMPORTANTE - Licoes aprendidas (ver Referencia-Integracao-GLPI.docx):
    - Endpoint correto: /apirest.php (NAO /api.php/v1 - retorna HTML)
    - Autenticacao: Basic Auth usuario:senha (user_token retorna "erro inesperado")
    - HTTP client: curl.exe obrigatorio (Invoke-RestMethod falha por TLS 1.0 no PS 5.x)
    - JSON: salvar em arquivo temporario sem BOM via [System.IO.File]::WriteAllText

.PARAMETER Servicos
    Lista de servicos a monitorar. Se omitido, usa a lista padrao definida no script.
    Aceita um ou mais nomes separados por virgula.

.EXAMPLE
    # Monitorar servicos especificos
    .\Monitor-ServicosGLPI.ps1 -Servicos "Spooler","DNS","Netlogon"

.EXAMPLE
    # Monitorar um unico servico
    .\Monitor-ServicosGLPI.ps1 -Servicos "MSSQLSERVER"

.EXAMPLE
    # Usar lista padrao (sem parametro)
    .\Monitor-ServicosGLPI.ps1

.EXAMPLE
    # Uso na Scheduled Task (Task Scheduler > Acoes > Argumentos):
    -NonInteractive -ExecutionPolicy Bypass -File "C:\TRUSTIT\Monitor-ServicosGLPI.ps1" -Servicos "Spooler","DNS","W32Time"

.NOTES
    Versao : 3.0 (parametro -Servicos via linha de comando)
    Autor  : TRUSTIT - Confianca e Tecnologia Ltda
    Uso    : Agende via Task Scheduler a cada 5-10 minutos
#>

param(
    [Parameter(Mandatory = $false, HelpMessage = "Servicos a monitorar. Ex: -Servicos 'Spooler','DNS'")]
    [string[]]$Servicos
)

# ============================================================
#  CONFIGURACOES - EDITE ESTA SECAO
# ============================================================

# Endpoint correto conforme documento de referencia TRUSTIT
$GLPI_URL       = "https://suporte.confiancaetecnologia.com.br/apirest.php"
$GLPI_APP_TOKEN = "DsGaJAyh8U9GnUdiMSKVH9s42GZeiiHk5GmIBz4y"

# Autenticacao via Basic Auth (user_token nao funciona neste ambiente)
# RECOMENDACAO: criar usuario dedicado ex: monitor.robot no GLPI
$GLPI_USER     = "script.integration"
$GLPI_PASSWORD = "Corolla!@#05042019"

# ============================================================
#  IDENTIFICACAO DO CLIENTE - ALTERE AQUI A CADA INSTALACAO
# ============================================================
# Informe o ID da entidade do cliente no GLPI.
# Consulte a tabela de entidades no final deste script.
# Exemplo: TrustIT > PM - Capitolio = ID 5
$GLPI_ENTITY_ID = 11  # TrustIT > CONSORCIO - CISUM

# Lista padrao de servicos (usada quando -Servicos nao e informado)
$SERVICOS_PADRAO = @(
    "Backup Service Controller",  # Agente de backup
    "tacticalrmm",                # Tactical RMM
    "Mesh Agent"                  # MeshCentral Agent
)

# Resolve quais servicos monitorar: parametro -Servicos ou lista padrao
if ($Servicos -and $Servicos.Count -gt 0) {
    $SERVICOS_MONITORADOS = $Servicos
} else {
    $SERVICOS_MONITORADOS = $SERVICOS_PADRAO
}

# Tentativas de reinicio antes de abrir chamado (0 = nao tenta)
$TENTATIVAS_REINICIO   = 1
$AGUARDAR_REINICIO_SEG = 15

# Prioridade do chamado
# 1=Muito baixa  2=Baixa  3=Media  4=Alta  5=Muito alta
$GLPI_URGENCY  = 4
$GLPI_PRIORITY = 4
$GLPI_TYPE         = 1    # 1=Incidente  2=Requisicao
$GLPI_CATEGORY_ID  = 131  # Servicos do Windows
$GLPI_REQUESTER_ID = 1491 # script.integration
$GLPI_ASSIGN_ID    = 1491 # Atribuido ao solucionar

# Pastas de trabalho
$WORK_DIR  = "C:\TRUSTIT"
$LOG_DIR   = "$WORK_DIR\Logs"
$DEDUP_DIR = "$WORK_DIR\Dedup"
$TEMP_JSON = "$WORK_DIR\glpi_payload_temp.json"
$LOG_FILE  = "$LOG_DIR\Monitor-Servicos.log"
$HOSTNAME  = $env:COMPUTERNAME

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

function Get-DedupFile([string]$Servico) {
    $nome = $Servico -replace '[\\/:*?"<>|]', '_'
    return Join-Path $DEDUP_DIR "ticket_$nome.lock"
}

function Chamado-JaAberto([string]$Servico) {
    return Test-Path (Get-DedupFile $Servico)
}

function Marcar-ChamadoAberto([string]$Servico, [string]$TicketId) {
    $TicketId | Set-Content -Path (Get-DedupFile $Servico) -Encoding UTF8
}

function Limpar-ChamadoAberto([string]$Servico) {
    $f = Get-DedupFile $Servico
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ============================================================
#  INTEGRACAO GLPI
#  Usa curl.exe - Invoke-RestMethod falha por TLS 1.0 no PS 5.x
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
        if ($data.session_token) {
            return $data.session_token
        }
        Write-Log "session_token nao retornado. Resposta bruta: $raw" "ERROR"
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
function Solucionar-Chamado {
    param(
        [string]$TicketId,
        [string]$SessionToken
    )
    # Registra solucao via ITILSolution e atualiza status + atribuido
    $dataHora = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    $descClean = "Servico reiniciado automaticamente pelo monitoramento TRUSTIT em $dataHora. Chamado solucionado automaticamente."

    # Passo 1: ITILSolution
    $json = "{""input"":{""items_id"":$TicketId,""itemtype"":""Ticket"",""content"":""$descClean""}}"
    [System.IO.File]::WriteAllText($TEMP_JSON, $json, [System.Text.Encoding]::ASCII)
    try {
        $raw = & curl.exe -s -k -X POST "$GLPI_URL/ITILSolution" `
            -H "Content-Type: application/json" `
            -H "Accept: application/json" `
            -H "App-Token: $GLPI_APP_TOKEN" `
            -H "Session-Token: $SessionToken" `
            -d "@$TEMP_JSON"
        $data = $raw | ConvertFrom-Json
        if ($data.id) {
            Write-Log "ITILSolution registrada no chamado #${TicketId}. ID solucao: $($data.id)" "INFO"
        } else {
            Write-Log "Aviso: ITILSolution nao retornou ID. Resposta: $raw" "WARN"
        }
    }
    catch { Write-Log "Excecao ao registrar ITILSolution: $_" "WARN" }
    finally { if (Test-Path $TEMP_JSON) { Remove-Item $TEMP_JSON -Force -ErrorAction SilentlyContinue } }

    # Passo 2: Atualiza status para Solucionado (5) e define Atribuido
    $json2 = "{""input"":{""id"":$TicketId,""status"":5,""_users_id_assign"":$GLPI_ASSIGN_ID}}"
    [System.IO.File]::WriteAllText($TEMP_JSON, $json2, [System.Text.Encoding]::ASCII)
    try {
        $raw2 = & curl.exe -s -k -X PUT "$GLPI_URL/Ticket/$TicketId" `
            -H "Content-Type: application/json" `
            -H "Accept: application/json" `
            -H "App-Token: $GLPI_APP_TOKEN" `
            -H "Session-Token: $SessionToken" `
            -d "@$TEMP_JSON"
        Write-Log "Chamado #${TicketId} marcado como Solucionado. Atribuido ao ID $GLPI_ASSIGN_ID." "INFO"
        return $true
    }
    catch {
        Write-Log "Excecao ao atualizar status do chamado #${TicketId}: $_" "WARN"
        return $false
    }
    finally { if (Test-Path $TEMP_JSON) { Remove-Item $TEMP_JSON -Force -ErrorAction SilentlyContinue } }
}

function Encerrar-Sessao([string]$SessionToken) {
    & curl.exe -s -k -X GET "$GLPI_URL/killSession" `
        -H "App-Token: $GLPI_APP_TOKEN" `
        -H "Session-Token: $SessionToken" | Out-Null
}

function Abrir-ChamadoGLPI {
    param(
        [string]$Servico,
        [string]$SessionToken,
        [ValidateSet("CRITICO","RECUPERADO")]
        [string]$Tipo = "CRITICO"
    )

    $dataHora = Get-Date -Format "dd/MM/yyyy HH:mm:ss"

    if ($Tipo -eq "RECUPERADO") {
        $titulo   = "[RECUPERADO] Servico reiniciado automaticamente: $Servico em $HOSTNAME"
        $urgencia = 2   # Baixa - situacao ja resolvida
        $conteudo = @"
<table border='0' cellpadding='6' cellspacing='0' style='font-family:Arial,sans-serif;font-size:13px;width:100%'>
  <tr style='background-color:#1a7a3c;color:#ffffff'>
    <td colspan='2' style='padding:10px 14px;font-size:15px;font-weight:bold'>
      &#10003; Servico Recuperado Automaticamente
    </td>
  </tr>
  <tr style='background-color:#f0f8f0'>
    <td style='width:180px;font-weight:bold;color:#555'>Servidor</td>
    <td>$HOSTNAME</td>
  </tr>
  <tr>
    <td style='font-weight:bold;color:#555'>Servico</td>
    <td>$Servico</td>
  </tr>
  <tr style='background-color:#f0f8f0'>
    <td style='font-weight:bold;color:#555'>Ocorrencia detectada em</td>
    <td>$dataHora</td>
  </tr>
  <tr>
    <td style='font-weight:bold;color:#555'>Tentativas de reinicio</td>
    <td>$TENTATIVAS_REINICIO</td>
  </tr>
  <tr style='background-color:#f0f8f0'>
    <td style='font-weight:bold;color:#555'>Status atual</td>
    <td style='color:#1a7a3c;font-weight:bold'>Running (recuperado pelo script)</td>
  </tr>
  <tr>
    <td colspan='2' style='padding-top:10px;color:#555;font-style:italic'>
      O servico foi encontrado parado e reiniciado automaticamente pelo monitoramento TRUSTIT.<br>
      Recomenda-se verificar os logs do servico para identificar a causa da parada.
    </td>
  </tr>
  <tr style='background-color:#f9f9f9'>
    <td colspan='2' style='padding:8px 14px;font-size:11px;color:#999;border-top:1px solid #ddd'>
      Chamado gerado automaticamente por Monitor-ServicosGLPI.ps1 - TRUSTIT Confianca e Tecnologia
    </td>
  </tr>
</table>
"@
    }
    else {
        $titulo   = "[CRITICO] Servico parado: $Servico em $HOSTNAME"
        $urgencia = $GLPI_URGENCY
        $conteudo = @"
<table border='0' cellpadding='6' cellspacing='0' style='font-family:Arial,sans-serif;font-size:13px;width:100%'>
  <tr style='background-color:#c0392b;color:#ffffff'>
    <td colspan='2' style='padding:10px 14px;font-size:15px;font-weight:bold'>
      &#9888; Servico Parado - Intervencao Necessaria
    </td>
  </tr>
  <tr style='background-color:#fdf2f2'>
    <td style='width:180px;font-weight:bold;color:#555'>Servidor</td>
    <td>$HOSTNAME</td>
  </tr>
  <tr>
    <td style='font-weight:bold;color:#555'>Servico</td>
    <td>$Servico</td>
  </tr>
  <tr style='background-color:#fdf2f2'>
    <td style='font-weight:bold;color:#555'>Detectado em</td>
    <td>$dataHora</td>
  </tr>
  <tr>
    <td style='font-weight:bold;color:#555'>Tentativas de reinicio</td>
    <td>$TENTATIVAS_REINICIO (sem sucesso)</td>
  </tr>
  <tr style='background-color:#fdf2f2'>
    <td style='font-weight:bold;color:#555'>Status atual</td>
    <td style='color:#c0392b;font-weight:bold'>Parado (requer intervencao manual)</td>
  </tr>
  <tr>
    <td colspan='2' style='padding-top:10px;color:#555;font-style:italic'>
      O servico nao respondeu as tentativas de reinicio automatico.<br>
      Verifique o servidor e os logs do servico o mais breve possivel.
    </td>
  </tr>
  <tr style='background-color:#f9f9f9'>
    <td colspan='2' style='padding:8px 14px;font-size:11px;color:#999;border-top:1px solid #ddd'>
      Chamado gerado automaticamente por Monitor-ServicosGLPI.ps1 - TRUSTIT Confianca e Tecnologia
    </td>
  </tr>
</table>
"@
    }

    # Sanitiza titulo para JSON (aspas e quebras de linha)
    $tituloClean   = $titulo  -replace '"', "'" -replace "`n", " " -replace "`r", ""

    # Sanitiza HTML para JSON: escapa aspas duplas e remove quebras de linha
    $conteudoClean = $conteudo -replace '"', "'" -replace "`r`n", " " -replace "`n", " " -replace "`r", ""

    # Monta JSON e salva em arquivo temporario SEM BOM
    # CRITICO: Out-File e Set-Content adicionam BOM e causam ERROR_JSON_PAYLOAD_INVALID
    $json = "{""input"":{""name"":""$tituloClean"",""content"":""$conteudoClean""," +
            """urgency"":$urgencia,""impact"":$urgencia,""priority"":$urgencia,""type"":$GLPI_TYPE,""entities_id"":$GLPI_ENTITY_ID,""itilcategories_id"":$GLPI_CATEGORY_ID,""_users_id_requester"":$GLPI_REQUESTER_ID}}"

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
            Write-Log "Chamado aberto. ID: $($data.id) | Servico: $Servico | Tipo: $Tipo" "INFO"
            return "$($data.id)"
        }
        else {
            Write-Log "Falha ao abrir chamado. Resposta: $raw" "ERROR"
            return ""
        }
    }
    catch {
        Write-Log "Excecao ao abrir chamado no GLPI: $_" "ERROR"
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
Write-Log "=== Inicio da execucao | Host: $HOSTNAME ==="
Write-Log "Servicos a monitorar ($($SERVICOS_MONITORADOS.Count)): $($SERVICOS_MONITORADOS -join ', ')"

$sessionToken   = $null
$sessaoIniciada = $false

foreach ($servico in $SERVICOS_MONITORADOS) {

    Write-Log "Verificando: $servico"

    try {
        $svc = Get-Service -Name $servico -ErrorAction Stop
    }
    catch {
        Write-Log "[$servico] Nao encontrado neste servidor. Ignorando." "WARN"
        continue
    }

    if ($svc.Status -eq "Running") {
        Write-Log "[$servico] Running. OK."
        if (Chamado-JaAberto $servico) {
            Write-Log "[$servico] Servico recuperado. Removendo marcador de chamado." "INFO"
            Limpar-ChamadoAberto $servico
        }
        continue
    }

    Write-Log "[$servico] Status: $($svc.Status). ALERTA: servico fora do ar!" "WARN"

    # Inicia sessao GLPI antes do reinicio (necessario para abrir chamado em qualquer cenario)
    if (-not $sessaoIniciada) {
        Write-Log "Iniciando sessao na API GLPI em $GLPI_URL..."
        $basicAuth    = Get-BasicAuth
        $sessionToken = Obter-SessionToken -BasicAuth $basicAuth
        if (-not $sessionToken) {
            Write-Log "Falha na autenticacao GLPI. Encerrando." "ERROR"
            break
        }
        $sessaoIniciada = $true
        Write-Log "Sessao GLPI iniciada com sucesso."
        $glpiUserId = Get-GLPIUserId -BasicAuth $basicAuth -SessionToken $sessionToken
        Write-Log "ID do usuario requerente ($GLPI_USER): $glpiUserId"
        Set-EntidadeAtiva -SessionToken $sessionToken
    }

    # Tenta reiniciar
    $reiniciouOk = $false

    for ($i = 1; $i -le $TENTATIVAS_REINICIO; $i++) {
        Write-Log "[$servico] Tentativa de reinicio $i/$TENTATIVAS_REINICIO..."
        try {
            Start-Service -Name $servico -ErrorAction Stop
            Start-Sleep -Seconds $AGUARDAR_REINICIO_SEG
            if ((Get-Service -Name $servico).Status -eq "Running") {
                Write-Log "[$servico] Reiniciado com sucesso na tentativa $i." "INFO"
                $reiniciouOk = $true
                Limpar-ChamadoAberto $servico
                break
            }
        }
        catch {
            Write-Log "[$servico] Erro no reinicio: $_" "ERROR"
        }
    }

    # Servico foi recuperado pelo script
    if ($reiniciouOk) {
        if (Chamado-JaAberto $servico) {
            # Havia chamado aberto - soluciona ele
            $ticketExistente = (Get-Content (Get-DedupFile $servico) -ErrorAction SilentlyContinue | Out-String).Trim()
            Write-Log "[$servico] Solucionando chamado #$ticketExistente no GLPI..." "INFO"
            Solucionar-Chamado -TicketId $ticketExistente -SessionToken $sessionToken | Out-Null
            Limpar-ChamadoAberto $servico
        } else {
            # Nao havia chamado aberto - abre um informativo de recuperacao
            Write-Log "[$servico] Abrindo chamado informativo de recuperacao no GLPI..." "INFO"
            Abrir-ChamadoGLPI -Servico $servico -SessionToken $sessionToken -Tipo "RECUPERADO" | Out-Null
        }
        continue
    }

    # Servico continua parado - verifica anti-duplicidade
    if (Chamado-JaAberto $servico) {
        $ticketExistente = (Get-Content (Get-DedupFile $servico) -ErrorAction SilentlyContinue | Out-String).Trim()
        Write-Log "[$servico] Chamado #$ticketExistente ja aberto anteriormente. Nao abrira duplicata." "WARN"
        continue
    }

    # Abre chamado critico
    $ticketId = Abrir-ChamadoGLPI -Servico $servico -SessionToken $sessionToken -Tipo "CRITICO"

    if ($ticketId) {
        Marcar-ChamadoAberto -Servico $servico -TicketId $ticketId
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
