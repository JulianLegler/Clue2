from datetime import datetime

from psc.tracker import PodUsage

from experiment import Experiment
from flushing_queue import FlushingQueue

from experiment_autoscaling import ExperimentAutoscaling
from workload_runner import WorkloadRunner
from psc import ResourceTracker, NodeUsage
from os import path
import signal

import subprocess
import kubernetes
import logging
import time

class ExperimentRunner:

    def __init__(self, experiment: Experiment):
        self.experiment = experiment

    def run(self, observations_out_path: str = "data/default"):
        exp = self.experiment

        if len(exp.env.workload_settings) == 0:
            raise ValueError(f"cant run {exp.name} with empty workload settings")
        # todo: autoscaling is set up upon branch deployment but cleaned up here

        node_file = path.join(
            observations_out_path, f"measurements_node_{datetime.now().strftime('%d_%m_%Y_%H_%M')}.csv"
        )

        # noinspection PyProtectedMember
        node_channel = FlushingQueue(
            node_file, buffer_size=32, fields=NodeUsage._fields
        )

        pod_file = path.join(
            observations_out_path, f"measurements_pod_{datetime.now().strftime('%d_%m_%Y_%H_%M')}.csv"
        )

        # noinspection PyProtectedMember
        pod_channel = FlushingQueue(
            pod_file, buffer_size=32, fields=PodUsage._fields
        )

        # tracker = ResourceTracker(exp.prometheus, observations_channel, tracker_namespaces, 10)
        tracker = ResourceTracker(
            prometheus_url=exp.prometheus,
            node_channel=node_channel,
            pod_channel=pod_channel,
            namespaces=[exp.namespace] + exp.infrastrcutre_namespaces,
            interval=10,
        )

        with open(path.join(observations_out_path, "experiment.json"), "w") as f:
            f.write(exp.create_json())

        # 5. start workload
        # start resource tracker
        logging.debug("starting tracker")
        tracker.start()
        # MAIN timeout to kill the experiment after 2 min after the experiment should be over (to avoid hanging)
        timeout = exp.env.total_duration() + 2*60 + 30
        # noinspection PyUnusedLocal
        def cancel(sig, frame):
            tracker.stop()
            pod_channel.flush()
            node_channel.flush()
            signal.raise_signal(signal.SIGUSR1)  # raise signal to stop workload
            logging.warning(f"workload timeout ({timeout})s reached.")

        signal.signal(signal.SIGALRM, cancel)
        signal.signal(signal.SIGINT, cancel) #also cancle on control-C
        
        # time.sleep(30)  # wait for 120s before stressing the workload

        logging.info(f"starting workload with timeout {timeout}")
        signal.alarm(timeout)
        # deploy workload on different node or locally and wait for workload to be completed (or timeout)
        wlr = WorkloadRunner(experiment=exp)
        # will run remotely or locally based on experiment

        wlr.run_workload(observations_out_path)

        logging.info("finished running workload, stopping trackers and flushing channels")
        # stop resource tracker
        tracker.stop()
        node_channel.flush()
        pod_channel.flush()
        signal.alarm(0)  # cancel alarm


    def cleanup(self):
        """
        Remove sets for autoscaling, remove workload pods,
        """
        print("🧹 cleanup...")

        if self.experiment.autoscaling:
            ExperimentAutoscaling(self.experiment).cleanup_autoscaling()

        if self.experiment.colocated_workload:
            core = kubernetes.client.CoreV1Api()
            # noinspection PyBroadException
            try:
                core.delete_namespaced_pod(
                    name="loadgenerator", namespace=self.experiment.namespace
                )
            except Exception as e:
                logging.error("error cleaning up -- probably already deleted")
                pass

        subprocess.run(["helm", "uninstall", "teastore", "-n", self.experiment.namespace])
        subprocess.run(
            ["git", "checkout", "examples/helm/values.yaml"],
            cwd=path.join(self.experiment.env.teastore_path),
        )
        subprocess.run(
            ["git", "checkout", "tools/build_docker.sh"],
            cwd=path.join(self.experiment.env.teastore_path),
        )
