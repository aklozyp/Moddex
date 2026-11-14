package de.aklozyp.moddexbackend.model.dto

import de.aklozyp.moddexbackend.model.Instance

data class InstanceBootstrapResponse(
    val instance: Instance,
    val serverProperties: ServerPropertiesDto
)