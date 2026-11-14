package de.aklozyp.moddexbackend.api.server.service

import com.fasterxml.jackson.core.JsonGenerator
import com.fasterxml.jackson.core.io.IOContext
import com.fasterxml.jackson.core.io.OutputDecorator
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.JsonSerializer
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.SerializerProvider
import com.fasterxml.jackson.databind.module.SimpleModule
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import de.aklozyp.moddexbackend.api.server.controller.InstanceController
import de.aklozyp.moddexbackend.api.server.properties.InstancePropertiesController
import de.aklozyp.moddexbackend.api.server.properties.ServerPropertiesService
import de.aklozyp.moddexbackend.config.ModdexDirectories
import de.aklozyp.moddexbackend.model.Instance
import de.aklozyp.moddexbackend.model.ServerSettings
import de.aklozyp.moddexbackend.model.enums.ModLoader
import de.aklozyp.moddexbackend.model.mods.InstanceModList
import de.aklozyp.moddexbackend.services.Logger
import io.mockk.Runs
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.spyk
import io.mockk.verify
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.CsvSource
import org.junit.jupiter.params.provider.ValueSource
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put
import org.springframework.test.web.servlet.setup.MockMvcBuilders
import org.springframework.web.server.ResponseStatusException
import java.io.FilterOutputStream
import java.io.IOException
import java.io.OutputStream
import java.io.Writer
import java.nio.file.AccessDeniedException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileSystemException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFileAttributeView
import java.nio.file.attribute.PosixFileAttributes
import java.nio.file.attribute.PosixFilePermissions
import java.nio.file.attribute.UserPrincipalNotFoundException
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class InstanceConfigPersistenceTest {
    private val objectMapper = jacksonObjectMapper()
    private val logger: Logger = mockk(relaxed = true)
    private val logMessages: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val settings: ServerSettingsService = mockk()
    private val installer: InstanceInstallerService = mockk()
    private val modListStore: InstanceModListStore = mockk()
    private lateinit var stateDir: Path
    private lateinit var directories: ModdexDirectories
    private lateinit var service: InstanceService

    // Creation assigns the identity server-side; the fixture id reported by the
    // create call is tracked here because the request's client-supplied id is ignored.
    private var createdInstanceId: UUID? = null

    private val instanceDir: Path
        get() = directories.dataDir.resolve("instances/Atomic")
    private val configFile: Path
        get() = instanceDir.resolve("instance.json")

    @BeforeEach
    fun setUp() {
        stateDir = Files.createTempDirectory(Path.of("target").toAbsolutePath(), "instance-config-test-")
        directories = object : ModdexDirectories {
            override val configDir: Path = stateDir.resolve("config")
            override val dataDir: Path = stateDir.resolve("data")
            override val logsDir: Path = stateDir.resolve("logs")
        }
        every { settings.getServerSettings() } returns ServerSettings().apply {
            projectPath = directories.dataDir.toString()
            defaultJavaXmx = "4G"
            defaultJavaXms = "2G"
        }
        every { modListStore.ensure(any(), any()) } answers { InstanceModList(instanceId = secondArg()) }
        every { installer.downloadInstaller(any(), any()) } just Runs
        every { logger.info(capture(logMessages)) } just Runs
        every { logger.warn(capture(logMessages)) } just Runs
        every { logger.error(capture(logMessages)) } just Runs
        every { logger.debug(capture(logMessages)) } just Runs
        service = service()
        createdInstanceId = null
    }

    @AfterEach
    fun cleanUp() {
        Files.walk(stateDir).use { paths ->
            paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
        }
    }

    @Test
    fun initialCreationAndOverwritePublishCompleteConfigurationWithoutChangingLayout() {
        val created = service.createAndInstallInstance(request())
        val unrelatedFile = instanceDir.resolve(".instance.json-unrelated.pending")
        Files.writeString(unrelatedFile, "not owned by the writer")
        val update = request().copy(id = UUID.randomUUID(), name = "Renamed", description = "Updated", javaXmx = "8G")

        val updated = service.updateInstanceById(created.id!!, update)

        assertThat(updated.id).isEqualTo(created.id)
        assertThat(service.getInstancePath(created.id!!)).isEqualTo(instanceDir)
        assertThat(service.getInstanceById(created.id!!)).isEqualTo(update)
        assertThat(service.getAllInstances()).containsExactly(update)
        assertThat(objectMapper.readValue(configFile.toFile(), Instance::class.java)).isEqualTo(update)
        assertThat(Files.readString(configFile)).contains("\n", "\"name\" : \"Renamed\"")
        assertThat(Files.readString(unrelatedFile)).isEqualTo("not owned by the writer")
        assertFiles("instance.json", unrelatedFile.fileName.toString())
        verify(exactly = 1) { installer.downloadInstaller(any(), instanceDir) }
    }

    @ParameterizedTest
    @ValueSource(booleans = [false, true])
    fun partialSerializationFailurePreservesPreviousBytesOrLeavesTargetAbsent(alreadyExists: Boolean) {
        val previous = previousConfig(alreadyExists)
        val pendingFile = AtomicReference<Path>()
        val unrelatedFile = instanceDir.resolve(".instance.json-unrelated.pending")
        val failingMapper = serializingMapper {
            pendingFile.set(Files.list(instanceDir).use { paths ->
                paths.filter { it.fileName.toString().startsWith(".instance.json-") }.findFirst().orElse(null)
            })
            Files.writeString(unrelatedFile, "leave this file alone")
            throw IOException(SENSITIVE_FAILURE)
        }

        val failure = assertThrows<ResponseStatusException> { save(service(failingMapper), alreadyExists) }

        assertSafeFailure(failure)
        assertPrevious(previous)
        assertThat(pendingFile.get()).isNotNull()
        assertThat(Files.exists(pendingFile.get())).isFalse()
        verify(exactly = if (alreadyExists) 1 else 0) { installer.downloadInstaller(any(), any()) }
        if (alreadyExists) {
            // Updates never roll back: the live configuration and foreign files
            // in the instance directory stay untouched.
            assertThat(Files.readString(unrelatedFile)).isEqualTo("leave this file alone")
            assertFiles("instance.json", unrelatedFile.fileName.toString())
            service.updateInstanceById(createdInstanceId!!, request().copy(description = "Retry succeeded"))
            assertThat(service.getInstanceById(createdInstanceId!!).description).isEqualTo("Retry succeeded")
        } else {
            // A failed creation rolls back: the reserved directory is removed
            // entirely, so no seemingly ready instance remains.
            assertThat(Files.exists(instanceDir)).isFalse()
            assertThat(service.getAllInstances()).isEmpty()
        }
    }

    @ParameterizedTest
    @CsvSource("false,write", "true,write", "false,close", "true,close")
    fun partialOutputAndCloseFailuresDoNotPublishAndCleanPendingFiles(alreadyExists: Boolean, failureAt: String) {
        val previous = previousConfig(alreadyExists)
        val closed = AtomicBoolean()
        val injected = AtomicBoolean()
        val failingMapper = jacksonObjectMapper()
        failingMapper.factory.setOutputDecorator(object : OutputDecorator() {
            override fun decorate(context: IOContext, output: OutputStream): OutputStream =
                object : FilterOutputStream(output) {
                    override fun write(bytes: ByteArray, offset: Int, length: Int) {
                        if (failureAt == "write") {
                            out.write(bytes, offset, minOf(length, 24))
                            out.flush()
                            injected.set(true)
                            throw IOException(SENSITIVE_FAILURE)
                        }
                        out.write(bytes, offset, length)
                    }

                    override fun close() {
                        closed.set(true)
                        super.close()
                        if (failureAt == "close") {
                            injected.set(true)
                            throw IOException(SENSITIVE_FAILURE)
                        }
                    }
                }

            override fun decorate(context: IOContext, output: Writer): Writer = output
        })

        val failure = assertThrows<ResponseStatusException> { save(service(failingMapper), alreadyExists) }

        assertSafeFailure(failure)
        assertThat(injected.get()).isTrue()
        assertThat(closed.get()).isTrue()
        assertPrevious(previous)
        if (alreadyExists) assertFiles("instance.json") else assertThat(Files.exists(instanceDir)).isFalse()
    }

    @ParameterizedTest
    @CsvSource("false,denied", "true,denied", "false,unsupported", "true,unsupported")
    fun replacementFailuresKeepOldConfigurationOrAbsentTargetAndAllowRetry(
        alreadyExists: Boolean,
        failureType: String,
    ) {
        val previous = previousConfig(alreadyExists)
        val pendingFile = AtomicReference<Path>()
        val failingService = spyk(service)
        every { failingService.replaceInstanceFile(any(), any()) } answers {
            val source = firstArg<Path>()
            val target = secondArg<Path>()
            pendingFile.set(source)
            assertThat(source.parent).isEqualTo(instanceDir)
            assertThat(source).isNotEqualTo(target)
            assertThat(target).isEqualTo(configFile)
            assertThat(objectMapper.readValue(source.toFile(), Instance::class.java).description).isEqualTo("Updated")
            assertPrevious(previous)
            if (failureType == "unsupported") {
                throw AtomicMoveNotSupportedException(source.toString(), target.toString(), SENSITIVE_FAILURE)
            }
            throw AccessDeniedException(source.toString(), target.toString(), SENSITIVE_FAILURE)
        }

        val failure = assertThrows<ResponseStatusException> { save(failingService, alreadyExists) }

        assertSafeFailure(failure)
        assertThat(pendingFile.get()).isNotNull()
        assertThat(Files.exists(pendingFile.get())).isFalse()
        assertPrevious(previous)
        if (alreadyExists) assertFiles("instance.json") else assertThat(Files.exists(instanceDir)).isFalse()
        verify(exactly = if (alreadyExists) 1 else 0) { installer.downloadInstaller(any(), any()) }
        val retried = if (alreadyExists) save(service, true) else service.createAndInstallInstance(request())
        assertThat(service.getInstanceById(retried.id!!)).isEqualTo(retried)
        // The rollback freed the reservation, so the retried creation reuses
        // the plain directory name instead of a suffixed one.
        if (!alreadyExists) assertThat(service.getInstancePath(retried.id!!)).isEqualTo(instanceDir)
    }

    @Test
    fun realReplacementFailureOnCreationRollsBackWithoutReplacingTheBlockingTarget() {
        val failingService = spyk(service)
        every { failingService.replaceInstanceFile(any(), any()) } answers {
            Files.createDirectory(configFile)
            Files.writeString(configFile.resolve("keep"), "existing directory contents")
            callOriginal()
        }

        val failure = assertThrows<ResponseStatusException> { save(failingService, false) }

        assertSafeFailure(failure)
        // The blocking directory at the target is never replaced in place; the
        // failed creation rolls back and removes the reserved directory with it.
        assertThat(Files.exists(instanceDir)).isFalse()
        assertThat(service.getAllInstances()).isEmpty()
        verify(exactly = 0) { installer.downloadInstaller(any(), any()) }
    }

    @ParameterizedTest
    @ValueSource(booleans = [false, true])
    fun readersSeeOnlyPreviousOrFullyPublishedConfigurationDuringSerialization(alreadyExists: Boolean) {
        val previous = previousConfig(alreadyExists)
        val partiallyWritten = CountDownLatch(1)
        val finishSerialization = CountDownLatch(1)
        val observingMapper = serializingMapper {
            partiallyWritten.countDown()
            check(finishSerialization.await(10, SECONDS))
        }
        val executor = Executors.newSingleThreadExecutor()
        try {
            val writer = executor.submit<Instance> { save(service(observingMapper), alreadyExists) }
            assertThat(partiallyWritten.await(10, SECONDS)).isTrue()
            assertThat(Files.size(onlyPendingFile())).isGreaterThan(0)
            assertPrevious(previous)
            if (alreadyExists) {
                assertThat(service.getAllInstances().single().description).isEqualTo("Original")
                assertThat(service.getInstanceById(createdInstanceId!!).description).isEqualTo("Original")
            } else {
                assertThat(service.getAllInstances()).isEmpty()
                assertThat(assertThrows<ResponseStatusException> { service.getInstanceById(INSTANCE_ID) }
                    .statusCode.value()).isEqualTo(404)
            }
            finishSerialization.countDown()
            val published = writer.get(10, SECONDS)
            assertThat(service.getInstanceById(published.id!!)).isEqualTo(published)
            assertThat(service.getAllInstances()).containsExactly(published)
            assertFiles("instance.json")
        } finally {
            finishSerialization.countDown()
            executor.shutdownNow()
            assertThat(executor.awaitTermination(10, SECONDS)).isTrue()
        }
    }

    @Test
    fun replacementPreservesExistingPosixPermissionsAndOwnership() {
        previousConfig(true)
        assumeTrue(Files.getFileStore(configFile).supportsFileAttributeView("posix"))
        val permissions = PosixFilePermissions.fromString("rw-r-----")
        Files.setPosixFilePermissions(configFile, permissions)
        val previous = Files.readAttributes(configFile, PosixFileAttributes::class.java)

        save(service, true)

        val published = Files.readAttributes(configFile, PosixFileAttributes::class.java)
        assertThat(published.permissions()).isEqualTo(permissions)
        assertThat(published.owner()).isEqualTo(previous.owner())
        assertThat(published.group()).isEqualTo(previous.group())
        assertFiles("instance.json")
    }

    @Test
    fun replacementPreservesNonDefaultPosixGroupWhenFixtureCanAssignOne() {
        previousConfig(true)
        assumeTrue(Files.getFileStore(configFile).supportsFileAttributeView("posix"))
        val view = Files.getFileAttributeView(configFile, PosixFileAttributeView::class.java)
        val originalGroup = view.readAttributes().group()
        val lookup = configFile.fileSystem.userPrincipalLookupService
        val alternateGroupAssigned = listOf("everyone", "users", "staff", "docker", "admin").any { name ->
            try {
                val group = lookup.lookupPrincipalByGroupName(name)
                if (group == originalGroup) false
                else {
                    view.setGroup(group)
                    true
                }
            } catch (_: UserPrincipalNotFoundException) {
                false
            } catch (_: FileSystemException) {
                false
            }
        }
        assumeTrue(alternateGroupAssigned, "Fixture requires permission to assign a different local group")
        val previous = view.readAttributes()
        val observingService = spyk(service)
        every { observingService.preserveInstanceFileAttributes(any(), any()) } answers {
            val pending = Files.readAttributes(firstArg<Path>(), PosixFileAttributes::class.java)
            assertThat(pending.group()).isEqualTo(originalGroup).isNotEqualTo(previous.group())
            callOriginal()
        }

        save(observingService, true)

        val published = Files.readAttributes(configFile, PosixFileAttributes::class.java)
        assertThat(published.owner()).isEqualTo(previous.owner())
        assertThat(published.group()).isEqualTo(previous.group())
        assertThat(published.permissions()).isEqualTo(previous.permissions())
        verify(exactly = 1) { observingService.preserveInstanceFileAttributes(any(), any()) }
        assertFiles("instance.json")
    }

    @Test
    fun attributePreservationFailureKeepsOldBytesOwnershipAndPermissionsAndCleansPendingFile() {
        val previous = previousConfig(true)
        assumeTrue(Files.getFileStore(configFile).supportsFileAttributeView("posix"))
        val attributes = Files.readAttributes(configFile, PosixFileAttributes::class.java)
        val pendingFile = AtomicReference<Path>()
        val failingService = spyk(service)
        every { failingService.preserveInstanceFileAttributes(any(), any()) } answers {
            pendingFile.set(firstArg())
            assertThat(objectMapper.readValue(pendingFile.get().toFile(), Instance::class.java).description)
                .isEqualTo("Updated")
            throw AccessDeniedException(pendingFile.get().toString(), null, SENSITIVE_FAILURE)
        }

        val failure = assertThrows<ResponseStatusException> { save(failingService, true) }

        assertSafeFailure(failure)
        assertPrevious(previous)
        val unchanged = Files.readAttributes(configFile, PosixFileAttributes::class.java)
        assertThat(unchanged.owner()).isEqualTo(attributes.owner())
        assertThat(unchanged.group()).isEqualTo(attributes.group())
        assertThat(unchanged.permissions()).isEqualTo(attributes.permissions())
        assertThat(pendingFile.get()).isNotNull()
        assertThat(Files.exists(pendingFile.get())).isFalse()
        assertFiles("instance.json")
    }

    @ParameterizedTest
    @ValueSource(booleans = [false, true])
    fun finalComponentSymlinkIsRejectedWithoutChangingLinkOrReferent(relativeLink: Boolean) {
        val previous = previousConfig(true)
        val referent = stateDir.resolve("shared-instance.json")
        Files.move(configFile, referent)
        val link = if (relativeLink) instanceDir.relativize(referent) else referent
        Files.createSymbolicLink(configFile, link)

        val failure = assertThrows<ResponseStatusException> { save(service, true) }

        assertSafeFailure(failure)
        assertThat(Files.isSymbolicLink(configFile)).isTrue()
        assertThat(Files.readSymbolicLink(configFile)).isEqualTo(link)
        assertThat(Files.readAllBytes(referent)).isEqualTo(previous)
        assertThat(service.getInstanceById(createdInstanceId!!).description).isEqualTo("Original")
        assertFiles("instance.json")
    }

    @Test
    fun parentDirectorySymlinkRemainsUsableAndUnchangedDuringAtomicUpdate() {
        previousConfig(true)
        val referent = stateDir.resolve("relocated-instance")
        Files.move(instanceDir, referent)
        Files.createSymbolicLink(instanceDir, referent)

        val updated = save(service, true)

        assertThat(Files.isSymbolicLink(instanceDir)).isTrue()
        assertThat(Files.readSymbolicLink(instanceDir)).isEqualTo(referent)
        assertThat(objectMapper.readValue(referent.resolve("instance.json").toFile(), Instance::class.java))
            .isEqualTo(updated)
        assertThat(service.getInstanceById(createdInstanceId!!)).isEqualTo(updated)
        assertFiles("instance.json")
    }

    @ParameterizedTest
    @ValueSource(strings = ["create", "bootstrap", "update"])
    fun instanceHttpWritersReportSanitized500OnPersistenceFailure(operation: String) {
        val previous = previousConfig(operation == "update")
        val failingService = service(serializingMapper { throw IOException(SENSITIVE_FAILURE) })
        val properties: ServerPropertiesService = mockk(relaxed = true)
        val mvc = MockMvcBuilders.standaloneSetup(
            InstanceController(failingService, mockk(), mockk(), logger),
            InstancePropertiesController(failingService, properties, logger),
        ).build()
        val builder = when (operation) {
            "update" -> put("/api/v1/instance/$createdInstanceId")
            "bootstrap" -> post("/api/v1/instance/bootstrap")
            else -> post("/api/v1/instance")
        }

        val result = mvc.perform(builder.contentType(MediaType.APPLICATION_JSON)
            .content(objectMapper.writeValueAsString(request().copy(description = SENSITIVE_FAILURE)))).andReturn()

        assertThat(result.response.status).isEqualTo(500)
        assertThat(result.response.errorMessage).contains("Check", "then retry")
        assertSafeFailure(result.resolvedException as ResponseStatusException)
        assertThat(result.response.contentAsString).doesNotContain(SENSITIVE_FAILURE)
        assertPrevious(previous)
        if (operation == "update") assertFiles("instance.json") else assertThat(Files.exists(instanceDir)).isFalse()
        verify(exactly = 0) { properties.initializeForInstance(any()) }
        verify(exactly = if (operation == "update") 1 else 0) { installer.downloadInstaller(any(), any()) }
    }

    @Test
    fun malformedReaderInputDoesNotLogRawJsonOrSecretParserMessages() {
        previousConfig(true)
        Files.writeString(configFile, """{"description":"$SENSITIVE_FAILURE","broken":""")

        assertThat(service.getAllInstances()).isEmpty()

        assertThat(logMessages.joinToString()).doesNotContain(SENSITIVE_FAILURE)
    }

    private fun service(mapper: ObjectMapper = objectMapper) =
        InstanceService(settings, mapper, installer, modListStore, logger, directories)

    private fun request() = Instance(
        // The client-supplied id is ignored on create since #258; the server
        // generates the identity and previousConfig tracks it after the call.
        id = INSTANCE_ID, name = "Atomic", description = "Original",
        gameVersion = "1.20.4", modLoader = ModLoader.VANILLA,
    )

    private fun previousConfig(alreadyExists: Boolean): ByteArray? {
        if (!alreadyExists) return null
        createdInstanceId = service.createAndInstallInstance(request()).id
        return Files.readAllBytes(configFile)
    }

    private fun save(writer: InstanceService, alreadyExists: Boolean): Instance {
        val update = request().copy(description = "Updated")
        return if (alreadyExists) writer.updateInstanceById(createdInstanceId!!, update)
        else writer.createAndInstallInstance(update)
    }

    private fun assertPrevious(previous: ByteArray?) {
        if (previous == null) {
            assertThat(Files.exists(configFile)).isFalse()
        } else {
            assertThat(Files.readAllBytes(configFile)).isEqualTo(previous)
            assertThat(objectMapper.readValue(configFile.toFile(), Instance::class.java).description).isEqualTo("Original")
        }
    }

    private fun onlyPendingFile(): Path = Files.list(instanceDir).use { paths ->
        paths.filter { it.fileName.toString().startsWith(".instance.json-") }.toList().single()
    }

    private fun assertFiles(vararg names: String) {
        Files.list(instanceDir).use { paths ->
            assertThat(paths.map { it.fileName.toString() }.toList()).containsExactlyInAnyOrder(*names)
        }
    }

    private fun assertSafeFailure(failure: ResponseStatusException) {
        assertThat(failure.statusCode.value()).isEqualTo(500)
        assertThat(failure.cause).isNull()
        assertThat(failure.reason).contains("Check", "then retry")
        assertThat(failure.toString() + logMessages.joinToString()).doesNotContain(SENSITIVE_FAILURE)
    }

    private fun serializingMapper(afterFlush: () -> Unit): ObjectMapper {
        val module = SimpleModule().addSerializer(Instance::class.java, object : JsonSerializer<Instance>() {
            override fun serialize(value: Instance, generator: JsonGenerator, provider: SerializerProvider) {
                generator.writeStartObject()
                generator.writeStringField("id", value.id?.toString())
                generator.flush()
                afterFlush()
                objectMapper.valueToTree<JsonNode>(value).fields().forEachRemaining { (name, node) ->
                    if (name != "id") {
                        generator.writeFieldName(name)
                        generator.writeTree(node)
                    }
                }
                generator.writeEndObject()
            }
        })
        return jacksonObjectMapper().registerModule(module)
    }

    companion object {
        private val INSTANCE_ID = UUID.fromString("11111111-1111-1111-1111-111111111111")
        private const val SENSITIVE_FAILURE = "test-password test-token test-provider-key raw-json-not-for-logs"
    }
}
