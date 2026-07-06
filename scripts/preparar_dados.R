options(repos = c(CRAN = "https://cloud.r-project.org"))

required_packages <- c("geobr", "sidrar", "readr", "dplyr", "sf", "leaflet", "arrow")

install_if_missing <- function(packages) {
  installed <- rownames(installed.packages())
  missing <- setdiff(packages, installed)

  if (length(missing) > 0) {
    message("Instalando pacotes ausentes: ", paste(missing, collapse = ", "))
    install.packages(missing)
  }
}

script_path <- function() {
  file_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(file_arg) == 0) {
    stop("Execute este arquivo com Rscript scripts/preparar_dados.R")
  }
  normalizePath(sub("^--file=", "", file_arg[[1]]), mustWork = TRUE)
}

reinstall_geobr_and_restart <- function() {
  if (identical(Sys.getenv("AULA_R_GEO_GEOBR_RETRY"), "1")) {
    stop(
      "A leitura com geobr falhou mesmo apos reinstalar o pacote. ",
      "Verifique a conexao com a internet e tente novamente."
    )
  }

  message("A leitura com geobr falhou. Reinstalando/atualizando geobr...")
  status_install <- system2(
    file.path(R.home("bin"), "Rscript"),
    c(
      "-e",
      shQuote("install.packages('geobr', repos = 'https://cloud.r-project.org')")
    )
  )

  if (!identical(status_install, 0L)) {
    stop("Nao foi possivel reinstalar geobr.")
  }

  message("geobr reinstalado. Reiniciando a preparacao dos dados...")
  status_restart <- system2(
    file.path(R.home("bin"), "Rscript"),
    script_path(),
    env = c("AULA_R_GEO_GEOBR_RETRY=1")
  )
  quit(status = status_restart)
}

read_municipios_rj_parquet <- function() {
  message("Usando fallback com metadados do geobr e leitura via arrow...")

  metadata <- geobr:::download_metadata2()
  if (is.null(metadata)) {
    stop("Nao foi possivel obter os metadados do geobr.")
  }

  asset <- metadata |>
    dplyr::filter(
      .data[["geo"]] == "municipalities",
      .data[["year"]] == "2022",
      .data[["simplified"]]
    ) |>
    dplyr::pull(.data[["file_name"]]) |>
    utils::head(1)

  if (length(asset) == 0 || is.na(asset)) {
    stop("Nao foi possivel localizar a malha municipal de 2022 nos metadados do geobr.")
  }

  data_release <- get("geobr_env", asNamespace("geobr"))$data_release
  url <- paste0(
    "https://github.com/ipea/geobr_prep_data/releases/download/",
    data_release,
    "/",
    asset
  )
  temp_file <- file.path(tempdir(), asset)

  utils::download.file(url, temp_file, mode = "wb", quiet = TRUE)

  dados <- arrow::read_parquet(temp_file) |>
    dplyr::filter(.data[["code_state"]] == 33)

  geometria <- sf::st_as_sfc(dados$geometry, EWKB = TRUE, crs = 4674)

  sf::st_sf(
    dados |> dplyr::select(-geometry),
    geometry = geometria,
    crs = 4674
  )
}

read_municipios_rj <- function() {
  result <- try(
    geobr::read_municipality(
      code_muni = "RJ",
      year = 2022,
      simplified = TRUE,
      showProgress = FALSE,
      cache = FALSE
    ),
    silent = TRUE
  )

  if (inherits(result, "try-error") || is.null(result)) {
    if (identical(Sys.getenv("AULA_R_GEO_GEOBR_RETRY"), "1")) {
      return(read_municipios_rj_parquet())
    }
    reinstall_geobr_and_restart()
  }

  result
}

message("Verificando pacotes...")
install_if_missing(required_packages)

for (package in required_packages) {
  if (!requireNamespace(package, quietly = TRUE)) {
    stop("Nao foi possivel carregar o pacote: ", package)
  }
}

message("Baixando malha municipal oficial do RJ via geobr...")
municipios <- read_municipios_rj()

area_km2 <- as.numeric(sf::st_area(sf::st_transform(municipios, 5880))) / 1e6

municipios <- sf::st_sf(
  CD_MUN = as.character(municipios$code_muni),
  municipio = municipios$name_muni,
  area_km2 = area_km2,
  geometry = sf::st_geometry(municipios),
  crs = sf::st_crs(municipios)
)

message("Baixando populacao municipal oficial no SIDRA/IBGE...")
populacao_sidra <- sidrar::get_sidra(
  x = 6579,
  variable = 9324,
  period = "last",
  geo = "City",
  geo.filter = list(State = 33),
  header = TRUE
)

indicadores <- populacao_sidra |>
  dplyr::transmute(
    cod_mun = as.character(.data[["Município (Código)"]]),
    municipio = sub(" - RJ$", "", .data[["Município"]]),
    populacao = as.numeric(.data[["Valor"]]),
    ano_populacao = as.integer(.data[["Ano"]])
  ) |>
  dplyr::left_join(
    sf::st_drop_geometry(municipios) |>
      dplyr::transmute(cod_mun = CD_MUN, area_km2),
    by = "cod_mun"
  ) |>
  dplyr::mutate(
    densidade_hab_km2 = populacao / area_km2
  ) |>
  dplyr::arrange(municipio)

dir.create("dados", showWarnings = FALSE)

for (file in list.files("dados", pattern = "^municipios\\.", full.names = TRUE)) {
  unlink(file)
}

message("Gravando dados/municipios.shp...")
sf::st_write(municipios, "dados/municipios.shp", delete_layer = TRUE, quiet = TRUE)

message("Gravando dados/indicadores_municipais.csv...")
readr::write_csv(indicadores, "dados/indicadores_municipais.csv")

message("Dados preparados com sucesso.")
message("Municipios no shapefile: ", nrow(municipios))
message("Registros no CSV: ", nrow(indicadores))
message("Ano da populacao: ", paste(unique(indicadores$ano_populacao), collapse = ", "))
