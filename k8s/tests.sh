#!/bin/bash

[[ $1 == "-v" ]] && { shift; NOISY=yes; }

next() {
    echo "next test ########################################################"
#    read
}

defer() {
    defer_fn=$1
    report_error() {
	[[ -z $defer_fn ]] && return
	echo
	echo UNEXPECTEDERROR OCCURED. Cleaning up $defer_fn
	echo
	$defer_fn
    }
    trap report_error EXIT
}

run_test() {
    if [[ -v NOISY ]]; then
	$1
    else
	$1 2> ${1}.err.log
    fi
}

set -e
[[ -v NOISY ]] && set -x
test_1() {
    echo 1 Smoke test
    cleanup_1() {
	kubectl delete deployment nginx >&2
	kubectl wait --for=delete pod -l app=nginx >&2
    }
    defer cleanup_1
    kubectl create deployment nginx  --image=nginx:latest  >&2
    kubectl get pods -l app=nginx
    kubectl wait --for=create pod -l app=nginx >&2
    kubectl wait --for=condition=ready pod -l app=nginx >&2
    # kubectl wait --for jsonpath='{.status.state}'=AtLatestKnown sub mysub -n myns --timeout=3m
    POD_NAME=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].metadata.name}")
    kubectl port-forward --address 0.0.0.0 $POD_NAME 8080:80 &
    portpod=$!
    sleep 1
    # Expect browsing to http://mgr:8080 shows the nginx page
    echo Curl the new pod:
    curl http://mgr:8080 | grep h1
    echo
    kill $portpod
    cleanup_1
}

test_2() {
    echo 2 Connectivity
    cleanup_2(){
	kubectl delete pod test-pod-1 >&2
	kubectl delete pod test-pod-2 >&2
	kubectl wait --for=delete pod test-pod-1 test-pod-2 >&2
    }
    defer cleanup_2
    kubectl run test-pod-1 --image=nginx --overrides='{"spec":{"nodeName":"k8n0.dgreaves.com"}}' >&2
    kubectl run test-pod-2 --image=nginx --overrides='{"spec":{"nodeName":"k8n1.dgreaves.com"}}' >&2

    kubectl wait --for=create --for=condition=ready pod test-pod-1 test-pod-2 >&2
    #kubectl wait  pod -l app=nginx

    echo installing ping...
    IP=$(kubectl get pod test-pod-2 -o jsonpath='{.status.podIP}')
    kubectl exec -it test-pod-1 -- bash -c "DEBIAN_FRONTEND=noninteractive apt update && apt install -y iputils-ping && ping -c 3 $IP" | grep bytes
    # Expect it to ping
    cleanup_2
}

test_3() {
    echo 3 Internal DNS
    cleanup_3(){
	kubectl delete svc test-svc >&2
    }
    defer cleanup_3

    kubectl create service clusterip test-svc --tcp=80:80
    kubectl run dns-test --image=busybox --rm -i --restart=Never -- nslookup test-svc | grep -v ":53" | grep Address
    kubectl wait --for=delete pod dns-test >&2 || true
    kubectl run dns-test --image=debian:bookworm-slim --rm -i --restart=Never -- bash -c "DEBIAN_FRONTEND=noninteractive apt update && apt install -y dnsutils && host kubernetes.default" | grep "has address"
    kubectl wait --for=delete pod dns-test >&2 || true
    cleanup_3
}

test_4() {
    echo 4 External DNS
    cleanup_4(){
	kubectl delete deployment dnsdemo >&2
	kubectl wait --for=delete pod -l app=dnsdemo >&2
    }
    defer cleanup_4
    kubectl create deployment dnsdemo --image=httpd --port=80 >&2
    kubectl expose deployment dnsdemo --port=80 --type=LoadBalancer --name=dnsdemo-k8s  >&2
    kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' service/dnsdemo-k8s >&2
    # Look at the Endpoints IP and check a browser can get to it
    echo Do annotation
    kubectl annotate service  dnsdemo-k8s external-dns.alpha.kubernetes.io/hostname=test-dnsdemo-k8s.dgreaves.com.
    echo "Waiting for DNS update (31s)"
    sleep 31 # It checks every 30s so this is guaranteed to work
    echo Navigate to test-dnsdemo-k8s.dgreaves.com
    curl http://test-dnsdemo-k8s.dgreaves.com | cat

    echo Deleting service
    kubectl delete service dnsdemo-k8s >&2
    #kubectl get service
    kubectl wait --for=delete service/dnsdemo-k8s >&2

    # echo Delete the annotation and remove the deployment
    # kubectl annotate service  dnsdemo-k8s external-dns.alpha.kubernetes.io/hostname
    echo
    echo "Waiting for DNS update (31s)"
    sleep 31 # It checks every 30s so this is guaranteed to work
    echo Check that the domain name is no longer valid
    host test-dnsdemo-k8s.dgreaves.com || true
    cleanup_4
}

test_5() {
    echo 5 LoadBalancer
    cleanup_5(){
	kubectl delete deployment/nginx-lb-test >&2
	kubectl wait --for=delete pod -l app=nginx-lb-test >&2
	kubectl delete svc/nginx-lb >&2
    }
    defer cleanup_5

    kubectl create deployment nginx-lb-test --image=strm/helloworld-http >&2
    kubectl expose deployment nginx-lb-test --type=LoadBalancer --port=80 --name=nginx-lb >&2
    kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' service/nginx-lb >&2
    kubectl wait --for=condition=Ready pod -l app=nginx-lb-test >&2

    IP=$(kubectl get svc nginx-lb -o json | jq -r .status.loadBalancer.ingress[0].ip)
    echo Before scaling
    for i in {1..3}; do curl -s http://$IP ; done | sort -u

    kubectl scale deployment nginx-lb-test --replicas=3
    kubectl wait --for=condition=Ready pod -l app=nginx-lb-test >&2
    echo After scaling
    for i in {1..10}; do curl -s http://$IP ; done | sort -u

    cleanup_5
}

test_6() {
    echo 6 Storage
    cleanup_6(){
	kubectl delete pod test-topolvm-pod >&2 || true
	echo waiting for pod and pvc cleanup ...
	kubectl wait --for=delete pod test-topolvm-pod >&2  || true
	kubectl delete pvc test-topolvm-pvc >&2
    }
    defer cleanup_6

    # Create a test PVC
    cat <<EOF | kubectl apply -f - >&2
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-topolvm-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: topolvm-storage
EOF

    # Check if it provisions:
    kubectl get pvc test-topolvm-pvc  >&2
    kubectl get pv >&2

    # The PVC should show Bound status and a corresponding PV should be created.
    # Test 2: Mount the Volume in a Pod

    # Create a pod that uses the PVC
    cat <<EOF | kubectl apply -f - >&2
apiVersion: v1
kind: Pod
metadata:
  name: test-topolvm-pod
spec:
  containers:
  - name: test
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - name: test-storage
      mountPath: /data
  volumes:
  - name: test-storage
    persistentVolumeClaim:
      claimName: test-topolvm-pvc
EOF

    kubectl wait --for=condition=ready pod test-topolvm-pod >&2
    kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/test-topolvm-pvc >&2

    # Test 3: Verify Storage Functionality
    # Check pod is running and volume is mounted
    # kubectl get pod test-topolvm-pod
    echo Pod has these mounts
    kubectl describe pod test-topolvm-pod | grep -A2 Mounts

    echo
    echo Pod has /data and can create a test-file
    # Test writing to the volume
    kubectl exec test-topolvm-pod -- df -h /data
    kubectl exec test-topolvm-pod -- touch /data/test-file
    kubectl exec test-topolvm-pod -- ls -la /data

    # Test 4: Check LVM on Nodes

    # See which node the pod landed on
    # Check LVM on that node
    NODE=$(kubectl get pod test-topolvm-pod -o jsonpath='{.spec.nodeName}')
    echo
    echo Pod is on node $NODE with lvs:
    ssh root@$NODE "lvs k8s-storage"


    # Test 5: Volume Expansion (if enabled)
    # Expand the PVC
    kubectl patch pvc test-topolvm-pvc -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'

    echo
    allocated=$(kubectl get pvc test-topolvm-pvc -o template --template "{{.status.allocatedResources.storage}}")
    echo Waiting for PVC to expand to $allocated
    kubectl wait --for=jsonpath='{.status.capacity.storage}'=$allocated pvc/test-topolvm-pvc
    # Check expansion worked
    echo
    echo Pod now has 2Gi PVC and /data/
    kubectl get pvc test-topolvm-pvc | grep 2Gi
    kubectl exec test-topolvm-pod -- df -h /data

    cleanup_6
}

test_7() {
    echo 7 Ingress
    cleanup_7(){
	kubectl delete ingress ingress-test >&2
    }
    defer cleanup_7
    INGRESS_NAMESPACE=ingress-nginx
    POD_NAME=$(kubectl get pods -n $INGRESS_NAMESPACE -l app.kubernetes.io/name=ingress-nginx --field-selector=status.phase=Running -o name)
    echo Ingress version:
    kubectl exec $POD_NAME -n $INGRESS_NAMESPACE -- /nginx-ingress-controller --version

    # Check the service. If using an LB there should be an external IP
    echo
    echo External IP
    kubectl get service ingress-nginx-controller --namespace=ingress-nginx

    # When creating an ingress the rule sets the DNS name and points to
    # the service/port to expose. There can be a tls extra but all should
    # use the same wildcard in dgreaves.com
    kubectl create ingress ingress-test --class=nginx  --rule="ingress-test-k8s.dgreaves.com/*=ingressdemo:80" >&2
    echo
    echo Example Ingress
    kubectl describe ingress ingress-test

    cleanup_7
}

# test_XXX() {
#     echo XXX
#     cleanup_XXX(){
#     }
#     defer cleanup_XXX
#
#     cleanup_XXX
# }

if [[ $# -eq 0 ]]; then
    tests="1 2 3 4 5 6 7"
else
    tests=$*
fi
for test in $tests; do
    run_test test_$test
    next
done
defer ""
