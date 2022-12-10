package config

import (
	restclient "k8s.io/client-go/rest"
	"k8s.io/client-go/tools/record"
	componentbaseconfig "k8s.io/component-base/config"

	crdclientset "github.com/clusterpedia-io/clusterpedia/pkg/generated/clientset/versioned"
	"github.com/clusterpedia-io/clusterpedia/pkg/storage"
	synchromanageroptions "github.com/clusterpedia-io/clusterpedia/pkg/synchromanager/clustersynchro/options"
)

type Config struct {
	Kubeconfig    *restclient.Config
	CRDClient     *crdclientset.Clientset
	EventRecorder record.EventRecorder

	StorageFactory storage.StorageFactory
	WorkerNumber   int

	LeaderElection   componentbaseconfig.LeaderElectionConfiguration
	ClientConnection componentbaseconfig.ClientConnectionConfiguration

	ClusterReadiness *synchromanageroptions.ReadinessProbeOption
}
