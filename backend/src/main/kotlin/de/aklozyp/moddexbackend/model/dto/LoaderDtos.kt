package de.aklozyp.moddexbackend.model.dto


data class FabricLoaderMeta(
    val loader: LoaderInfo,
    val intermediary: Any?
) {
    data class LoaderInfo(val version: String, val stable: Boolean, val maven: String?)
}